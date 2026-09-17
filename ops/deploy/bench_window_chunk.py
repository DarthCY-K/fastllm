#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""bench_window_chunk.py BASE OUT TAG MODE — chunk/预填组合窗 bench。
MODE: full = w2k/d200_a/c32w1/c32w2/c32m/c64/c128/mt3/d200_b
      short = w2k/d200_a/c32w1/c32w2/c32m/c64/d200_b
      probe = w2k/d200_a/c32w1/c32w2/c32m
c32 三连文本与 ab7 完全一致（2026-09-17 基线 c32_m=27.907s / d200=3.307s 可直接比）。"""
import hashlib, json, sys, time, urllib.request

BASE = sys.argv[1].rstrip("/")
OUT = sys.argv[2]
TAG = sys.argv[3] if len(sys.argv) > 3 else "run"
MODE = sys.argv[4] if len(sys.argv) > 4 else "full"
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


def call(messages, max_tokens, timeout=1800):
    payload = {"model": "Qwen3.8-27B-W8A16", "messages": messages,
               "max_tokens": max_tokens, "stream": True, "temperature": 0.0,
               "chat_template_kwargs": {"enable_thinking": False}}
    req = urllib.request.Request(
        BASE + "/v1/chat/completions",
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        headers={"Authorization": "Bearer " + KEY, "Content-Type": "application/json"})
    t0 = time.monotonic(); ttft = None; parts = []; fin = None; usage = None
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
            if isinstance(j.get("usage"), dict):
                usage = j["usage"]
            ch = (j.get("choices") or [{}])[0]
            d = ch.get("delta") or {}
            piece = (d.get("content") or "") + (d.get("reasoning_content") or "")
            if piece:
                if ttft is None:
                    ttft = time.monotonic() - t0
                parts.append(piece)
            if ch.get("finish_reason"):
                fin = ch["finish_reason"]
    total = time.monotonic() - t0
    text = "".join(parts)
    ctok = (usage or {}).get("completion_tokens")
    return {"ttft": round(ttft, 3) if ttft is not None else None,
            "total": round(total, 3),
            "ctok": ctok if ctok is not None else len(parts),
            "ctok_src": "usage" if ctok is not None else "pieces",
            "md5": hashlib.md5(text.encode("utf-8")).hexdigest()[:12],
            "finish": fin, "last": text[-45:].replace("\n", " ")}, text


res = {"tag": TAG, "base": BASE, "mode": MODE, "when": time.strftime("%F %T"), "cases": []}


def run(name, content, max_tokens=1000):
    ptok = len(TOK.encode(content, add_special_tokens=False).ids)
    try:
        c, _ = call([{"role": "user", "content": content}], max_tokens)
    except Exception as e:
        c = {"error": repr(e)[:220]}
    c.update({"name": name, "ptok_est": ptok})
    res["cases"].append(c)
    print(name, json.dumps(c, ensure_ascii=False), flush=True)
    time.sleep(1)


COUNT100 = "\n\nNow count from 1 to 100, one number per line, no other text."

run("w2k", filler(2000, "AB7 warm.") + "\n\nReply with exactly W2K_OK.", 64)
run("d200_a", "AB7 a. Count from 1 to 200, one number per line, no other text.", 2000)
run("c32_w1", filler(32000, "AB7 w1.") + COUNT100)
run("c32_w2", filler(32000, "AB7 w2.") + COUNT100)
run("c32_m", filler(32000, "AB7 m.") + COUNT100)
if MODE in ("full", "short"):
    run("c64", filler(64000, "CKW64.") + COUNT100)
if MODE == "full":
    run("c128", filler(128000, "CKW128.") + COUNT100)
if MODE == "full":
    mt = []
    try:
        q1 = filler(20000, "AB7 mt.") + COUNT100
        m1 = [{"role": "user", "content": q1}]
        c1, a1 = call(m1, 1000)
        m2 = m1 + [{"role": "assistant", "content": a1},
                   {"role": "user", "content": "Now count from 101 to 200, one number per line, no other text."}]
        c2, a2 = call(m2, 2000)
        m3 = m2 + [{"role": "assistant", "content": a2},
                   {"role": "user", "content": "Now count from 201 to 300, one number per line, no other text."}]
        c3, a3 = call(m3, 2000)
        for i, c in enumerate((c1, c2, c3), 1):
            mt.append({"turn": i, **{k: c[k] for k in ("ttft", "total", "ctok", "md5")}})
        print("mt3", json.dumps(mt, ensure_ascii=False), flush=True)
    except Exception as e:
        mt.append({"error": repr(e)[:220]})
    res["mt3"] = mt
run("d200_b", "AB7 b. Count from 1 to 200, one number per line, no other text.", 2000)

json.dump(res, open(OUT, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
print("SAVED", OUT, flush=True)
