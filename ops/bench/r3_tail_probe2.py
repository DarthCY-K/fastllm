#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""DFlash tail-chunk regression probe v2 — converges each prompt onto the 512-token
chunk grid so the FINAL chunk is <= 64 tokens (the path that used to drop the draft
seed), using response usage as ground truth and a unique prefix anchor per attempt
(so every attempt is a cold prompt and no prefix cache hides the tail path).

Usage: r3_tail_probe2.py <base_url> <out.json> <tag>
"""
import json, sys, time, urllib.request, urllib.error, hashlib
from tokenizers import Tokenizer

BASE = (sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8081").rstrip("/")
OUT = sys.argv[2] if len(sys.argv) > 2 else "/home/ai-agent/builds/upgrade-test/r3-tail-probe2.json"
TAG = sys.argv[3] if len(sys.argv) > 3 else "r3"
KEY = [l.split("=", 1)[1].strip().strip('"').strip("'")
       for l in open("/home/ai-agent/qwen38-0.2x.env", encoding="utf-8")
       if l.startswith("VLLM_API_KEY=")][0]
MODEL = "Qwen3.8-27B-W8A16"
CHUNK = 512
RATIO = 0.978          # filler decode->encode round-trip factor (measured 0.965-0.982)
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

def chat_ns(content, max_tokens=2, timeout=1800):
    st, body = http("/v1/chat/completions", {"model": MODEL, "messages": [{"role": "user", "content": content}],
        "max_tokens": max_tokens, "temperature": 0.0, "chat_template_kwargs": {"enable_thinking": False}}, timeout=timeout)
    if st != 200 or not isinstance(body, dict):
        return None
    return int(body.get("usage", {}).get("prompt_tokens", -1))

def chat_stream(content, max_tokens=320, timeout=1800):
    payload = {"model": MODEL, "messages": [{"role": "user", "content": content}],
               "max_tokens": max_tokens, "stream": True, "temperature": 0.0,
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
            b = line[6:]
            if b == "[DONE]":
                break
            try:
                j = json.loads(b)
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
            "last": text[-40:].replace("\n", " ")}

res = {"tag": TAG, "when": time.strftime("%F %T"), "base": BASE, "chunk": CHUNK, "checks": [], "probes": []}
def check(name, ok, detail):
    res["checks"].append({"name": name, "ok": bool(ok), "detail": str(detail)[:300]})
    print("[%s] %s :: %s" % ("PASS" if ok else "FAIL", name, str(detail)[:300]), flush=True)

off = (chat_ns("z", 4) or 13) - 1
res["template_offset"] = off
INSTR = "\n\nCount from 1 to 200, one number per line, no other text."
instr_tokens = ntok(INSTR)
print("template_offset=%d instr_tokens=%d" % (off, instr_tokens), flush=True)

def converge(target_mod, anchor, kind, want_le64=True, max_attempts=5):
    target_total = CHUNK * 31 + target_mod
    n = max(200, int(round((target_total - off - instr_tokens) / RATIO)))
    attempts = []
    for a in range(1, max_attempts + 1):
        content = filler(n, "%s attempt%d cold anchor:" % (anchor, a)) + INSTR
        st = chat_stream(content, 320)              # cold prompt -> exercises the tail path
        P = chat_ns(content)                        # exact prompt length (prefix hit)
        mod = (P % CHUNK) if P and P > 0 else None
        row = dict(st); row.update({"kind": kind, "attempt": a, "filler_requested": n,
                                    "prompt_tokens_actual": P, "mod_512": mod})
        attempts.append(row)
        print("%s attempt%d: filler=%d prompt_tokens=%s mod=%s ttft=%s decode=%s md5=%s" %
              (kind, a, n, P, mod, row["ttft"], row["decode_tps_client"], row["md5"]), flush=True)
        hit = (mod is not None) and ((0 < mod <= 64) if want_le64 else (mod > 64))
        if hit:
            row["accepted"] = True
            res["probes"].append(row)
            return row
        if P and P > 0:
            n = max(200, n + int(round((target_total - P) / RATIO)))
        time.sleep(0.5)
    attempts[-1]["accepted"] = False
    res["probes"].append(attempts[-1])
    fs = sum(1 for x in attempts for k in ("target",))
    return attempts[-1]

rows = [converge(16, "Tail probe woodpecker amber", "tail16", True),
        converge(62, "Tail probe glacier violin", "tail62", True),
        converge(300, "Tail probe compass meadow", "control300", False)]

for r in rows:
    nm = r["kind"]
    check("precondition_%s" % nm, r.get("accepted", False),
          "prompt_tokens=%s mod_512=%s attempts=%s" % (r["prompt_tokens_actual"], r["mod_512"], r["attempt"]))
    check("decode_%s" % nm, (r["decode_tps_client"] or 0) > 120,
          "decode=%.1f tok/s (degraded ~52 / healthy ~200+), ttft=%s" % (r["decode_tps_client"] or -1, r["ttft"]))

cont = filler(rows[-1]["filler_requested"], "Post-probe continuation cold anchor:") + \
       "\n\nNow reply with exactly TURN2_OK and nothing else."
st = chat_stream(cont, 32)
res["turn2"] = st
check("turn2_ok", "TURN2_OK" in st["last"], "%s ttft=%s" % (st["last"], st["ttft"]))

res["ok"] = all(x["ok"] for x in res["checks"])
json.dump(res, open(OUT, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
print("TAIL_PROBE2 ok=%s fails=%d saved=%s" % (res["ok"], sum(1 for x in res["checks"] if not x["ok"]), OUT), flush=True)
