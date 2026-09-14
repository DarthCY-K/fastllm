# -*- coding: utf-8 -*-
"""SCAN bench v2: per-config compact suite + long-prefill point
(w2k warm / d200_a / c32_m / c64_m prefill / d200_b).
All prompts uniquely tagged per config -> cold. Client decode_tps included."""
import json, sys, time, urllib.request, hashlib, re

BASE = sys.argv[1].rstrip("/")
OUT = sys.argv[2]
TAG = sys.argv[3] if len(sys.argv) > 3 else "scan"
KEY = [l.split("=", 1)[1].strip().strip('"').strip("'")
       for l in open("/home/ai-agent/qwen38-0.2x.env", encoding="utf-8")
       if l.startswith("VLLM_API_KEY=")][0]
from tokenizers import Tokenizer
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

def call(messages, temperature, max_tokens, timeout=1200):
    payload = {"model": "Qwen3.8-27B-W8A16", "messages": messages,
               "max_tokens": max_tokens, "stream": True, "temperature": temperature,
               "chat_template_kwargs": {"enable_thinking": False}}
    if temperature > 0:
        payload["top_p"] = 0.95
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
            ch = (j.get("choices") or [{}])[0]; d = ch.get("delta") or {}
            piece = (d.get("content") or "") + (d.get("reasoning_content") or "")
            if piece:
                if ttft is None:
                    ttft = time.monotonic() - t0
                parts.append(piece)
            if ch.get("finish_reason"):
                fin = ch.get("finish_reason")
    total = time.monotonic() - t0
    text = "".join(parts)
    ctok = len(TOK.encode(text, add_special_tokens=False).ids)
    dec = round(ctok / max(total - (ttft or 0), 1e-6), 1) if ttft else -1
    c = {"ttft": round(ttft or -1, 3), "total": round(total, 3), "ctok": ctok,
         "dec": dec, "finish": fin, "md5": hashlib.md5(text.encode()).hexdigest()[:12],
         "last": text[-40:].replace("\n", " ")}
    return c

res = {"tag": TAG, "base": BASE, "when": time.strftime("%F %T"), "cases": []}

def run(name, content, temperature=0.0, max_tokens=1000):
    ptok = len(TOK.encode(content, add_special_tokens=False).ids)
    try:
        c = call([{"role": "user", "content": content}], temperature, max_tokens)
    except Exception as e:
        c = {"error": repr(e)[:220]}
    c.update({"name": name, "ptok_est": ptok})
    res["cases"].append(c)
    print(name, json.dumps(c, ensure_ascii=False), flush=True)
    time.sleep(1)

run("w2k", filler(2000, "SCAN %s warm." % TAG) + "\n\nReply with exactly W2K_OK.", 0.0, 64)
run("d200_a", "SCAN %s a. Count from 1 to 200, one number per line, no other text." % TAG, 0.0, 2000)
run("c32_m", filler(32000, "SCAN %s m." % TAG) + "\n\nNow count from 1 to 100, one number per line, no other text.", 0.0, 1000)
run("c64_m", filler(64000, "SCAN %s m64." % TAG) + "\n\nNow count from 1 to 100, one number per line, no other text.", 0.0, 1000)
run("d200_b", "SCAN %s b. Count from 1 to 200, one number per line, no other text." % TAG, 0.0, 2000)

json.dump(res, open(OUT, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
print("SAVED", OUT, flush=True)
