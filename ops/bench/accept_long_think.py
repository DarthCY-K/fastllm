# -*- coding: utf-8 -*-
"""accept_long_think.py BASE — 封版验收：真实画像长输出基准。
A) 短上下文 + thinking 长输出（编码题，4K max）——对标日常 Pi 用法。
B) 32K 上下文 + 长解码（count 1..1000，确定性 md5 可对比）。"""
import json, sys, time, urllib.request, hashlib

BASE = sys.argv[1].rstrip("/")
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

def call(content, thinking, max_tokens, timeout=900):
    payload = {"model": "Qwen3.8-27B-W8A16", "messages": [{"role": "user", "content": content}],
               "max_tokens": max_tokens, "stream": True, "temperature": 0.0,
               "chat_template_kwargs": {"enable_thinking": thinking}}
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
    return {"ttft": round(ttft or -1, 3), "total": round(total, 3), "ctok": ctok,
            "dec": dec, "finish": fin, "md5": hashlib.md5(text.encode()).hexdigest()[:12],
            "tail": text[-60:].replace("\n", " ")}

print("A think-long:", json.dumps(call(
    "请用 Python 实现一个线程安全的 LRU 缓存类（容量固定、支持逐出回调），给出完整实现、3 个单元测试，并解释设计思路。",
    True, 4096), ensure_ascii=False), flush=True)
print("B 32k-count1000:", json.dumps(call(
    filler(32000, "ACCEPT 32k.") + "\n\nCount from 1 to 1000, one number per line, no other text.",
    False, 4000), ensure_ascii=False), flush=True)
