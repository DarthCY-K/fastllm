#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""r3 probe: auth / models / chat / tool-call / DFlash tail-chunk / count200 determinism / multi-turn.

Usage: r3_probe.py <base_url> <out.json> <tag>
Runs against 8081 (test stack) or 8080 (production baseline). Key is read from the
box env file and never printed.
"""
import json, sys, time, urllib.request, urllib.error, hashlib
from tokenizers import Tokenizer

BASE = (sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8081").rstrip("/")
OUT = sys.argv[2] if len(sys.argv) > 2 else "/home/ai-agent/builds/upgrade-test/r3-probe.json"
TAG = sys.argv[3] if len(sys.argv) > 3 else "r3"
KEY = [l.split("=", 1)[1].strip().strip('"').strip("'")
       for l in open("/home/ai-agent/qwen38-0.2x.env", encoding="utf-8")
       if l.startswith("VLLM_API_KEY=")][0]
MODEL = "Qwen3.8-27B-W8A16"
TOK = Tokenizer.from_file(
    "/home/ai-agent/fastllm-video-repro/models/nerkyor/Qwen3.8-27B-EfficientThink-FP8-lm/tokenizer.json")
PARA = ("The old stone bridge arched over the river, its shadow trembling on the water. "
        "Lanterns swayed along the alley, and somewhere a bamboo flute practiced the same "
        "gentle phrase, over and over, until the night learned it by heart. ")

def filler(n, tag):
    ids = TOK.encode(tag + " " + PARA, add_special_tokens=False).ids
    buf = []
    while len(buf) < n:
        buf.extend(ids)
    return TOK.decode(buf[:n])

def ntok(s):
    return len(TOK.encode(s, add_special_tokens=False).ids)

def http(path, payload=None, key=True, timeout=1800):
    headers = {"Content-Type": "application/json"}
    if key:
        headers["Authorization"] = "Bearer " + KEY
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8") if payload is not None else None
    req = urllib.request.Request(BASE + path, data=data, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        try:
            body = json.loads(e.read().decode("utf-8"))
        except Exception:
            body = None
        return e.code, body

def chat_stream(content, temperature=0.0, max_tokens=320, timeout=1800):
    payload = {"model": MODEL, "messages": [{"role": "user", "content": content}],
               "max_tokens": max_tokens, "stream": True, "temperature": temperature,
               "chat_template_kwargs": {"enable_thinking": False}}
    req = urllib.request.Request(BASE + "/v1/chat/completions",
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        headers={"Authorization": "Bearer " + KEY, "Content-Type": "application/json"})
    t0 = time.monotonic(); ttft = None; parts = []; fin = None
    with urllib.request.urlopen(req, timeout=timeout) as r:
        for raw in r:
            line = raw.decode("utf-8", "ignore").strip()
            if not line.startswith("data: "):
                continue
            body = line[6:]
            if body == "[DONE]":
                break
            try:
                j = json.loads(body)
            except Exception:
                continue
            ch = (j.get("choices") or [{}])[0]
            d = ch.get("delta") or {}
            piece = (d.get("content") or "") + (d.get("reasoning_content") or "")
            if piece:
                if ttft is None:
                    ttft = time.monotonic() - t0
                parts.append(piece)
            if ch.get("finish_reason"):
                fin = ch.get("finish_reason")
    total = time.monotonic() - t0
    text = "".join(parts)
    ctok = ntok(text)
    return {"ttft": round(ttft or -1, 3), "total": round(total, 3), "ctok": ctok,
            "decode_tps_client": round(ctok / max(total - (ttft or 0), 1e-6), 1),
            "finish": fin, "md5": hashlib.md5(text.encode()).hexdigest()[:12],
            "last": text[-40:].replace("\n", " "), "text_head": text[:120].replace("\n", " ")}

res = {"tag": TAG, "when": time.strftime("%F %T"), "base": BASE, "checks": [], "raw": {}}
def check(name, ok, detail):
    res["checks"].append({"name": name, "ok": bool(ok), "detail": str(detail)[:300]})
    print("[%s] %s :: %s" % ("PASS" if ok else "FAIL", name, str(detail)[:300]), flush=True)

# 1) auth
st, _ = http("/v1/models", key=False, timeout=30)
check("no_auth_401", st == 401, "http=%s" % st)
st, body = http("/v1/models", timeout=30)
ids = [m.get("id") for m in (body or {}).get("data", [])] if isinstance(body, dict) else []
check("models_200", st == 200 and MODEL in ids, "http=%s ids=%s" % (st, ids))

# 2) template-offset calibration + warmup (tiny non-stream request with usage)
st, body = http("/v1/chat/completions", {"model": MODEL, "messages": [{"role": "user", "content": "x"}],
        "max_tokens": 4, "temperature": 0.0, "chat_template_kwargs": {"enable_thinking": False}}, timeout=300)
off = None
if st == 200 and isinstance(body, dict) and body.get("usage"):
    off = int(body["usage"].get("prompt_tokens", 0)) - ntok("x")
check("template_offset", off is not None, "prompt_tokens-1 = %s" % off)
if off is None:
    off = 12
res["raw"]["template_offset"] = off

# 3) chat smoke
c = chat_stream("Reply with exactly UPGRADE_SMOKE_OK and nothing else.", 0.0, 32)
res["raw"]["smoke"] = c
check("smoke_text", "UPGRADE_SMOKE_OK" in c["text_head"], c["text_head"])

# 4) tool call
try:
    st, body = http("/v1/chat/completions", {"model": MODEL,
        "messages": [{"role": "user", "content": "What is the weather in Beijing? Use the tool."}],
        "max_tokens": 300, "temperature": 0.0,
        "tools": [{"type": "function", "function": {"name": "get_weather",
            "description": "Get weather for a city",
            "parameters": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}}}],
        "tool_choice": "required",
        "chat_template_kwargs": {"enable_thinking": False}}, timeout=600)
    tc = ((body or {}).get("choices") or [{}])[0].get("message", {}).get("tool_calls")
    name = tc[0]["function"]["name"] if tc else None
    args = tc[0]["function"]["arguments"] if tc else None
    res["raw"]["tool"] = {"http": st, "name": name, "args": args}
    check("tool_call", name == "get_weather" and "Beijing" in str(args), "http=%s name=%s args=%s" % (st, name, args))
except Exception as e:
    check("tool_call", False, repr(e)[:200])

# 5) DFlash tail-chunk regression: prompt whose last chunk (512 grid) is <= 64 tokens
INSTR = "\n\nCount from 1 to 200, one number per line, no other text."
target_total = 512 * 31 + 40          # tail = 40 tokens on the 512-token chunk grid
want_filler = target_total - off - ntok(INSTR)
content = filler(want_filler, "R3 tail probe.") + INSTR
est_prompt = ntok(content) + off
tail = est_prompt % 512
res["raw"]["tail"] = {"est_prompt_tokens": est_prompt, "tail_mod_512": tail}
c = chat_stream(content, 0.0, 320)
res["raw"]["tail"].update(c)
check("tail_chunk_tail_le_64", 0 < tail <= 64, "est_prompt=%d tail_mod_512=%d" % (est_prompt, tail))
check("tail_chunk_no_slowdown", c["decode_tps_client"] > 120,
      "decode=%.1f tok/s (degraded path ~52, healthy ~200), md5=%s" % (c["decode_tps_client"], c["md5"]))

# 6) count200 determinism at ~2K context (same-window prod/test comparison)
INSTR2 = "\n\nCount from 1 to 200, one number per line, no other text."
content2 = filler(2000, "R3 count baseline.") + INSTR2
c2 = chat_stream(content2, 0.0, 512)
res["raw"]["count200"] = c2
check("count200_ran", c2["finish"] in ("length", "stop") and c2["ctok"] > 50,
      "finish=%s ctok=%d decode=%.1f md5=%s" % (c2["finish"], c2["ctok"], c2["decode_tps_client"], c2["md5"]))

# 7) multi-turn continuation on the 16K prefix (prefix-cache restore path)
cont = filler(want_filler, "R3 tail probe.") + "\n\nNow reply with exactly TURN2_OK and nothing else."
c3 = chat_stream(cont, 0.0, 32)
res["raw"]["turn2"] = c3
check("turn2_ok", "TURN2_OK" in c3["text_head"], "%s ttft=%.2f" % (c3["text_head"], c3["ttft"]))

res["ok"] = all(x["ok"] for x in res["checks"])
json.dump(res, open(OUT, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
print("PROBE_RESULT ok=%s fails=%d saved=%s" % (res["ok"],
      sum(1 for x in res["checks"] if not x["ok"]), OUT), flush=True)
