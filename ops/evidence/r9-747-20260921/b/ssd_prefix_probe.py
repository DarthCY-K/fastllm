# -*- coding: utf-8 -*-
"""ssd_prefix_probe.py BASE TAG — 固定 16K 前缀请求，打印 cached/md5（SSD 持久缓存观测）。"""
import json, sys, time, urllib.request, hashlib
BASE = sys.argv[1].rstrip("/")
TAG = sys.argv[2] if len(sys.argv) > 2 else "run"
KEY = [l.split("=", 1)[1].strip().strip('"').strip("'")
       for l in open("/home/ai-agent/qwen38-0.2x.env", encoding="utf-8")
       if l.startswith("VLLM_API_KEY=")][0]
from tokenizers import Tokenizer
TOK = Tokenizer.from_file(
    "/home/ai-agent/fastllm-video-repro/models/nerkyor/Qwen3.8-27B-EfficientThink-FP8-lm/tokenizer.json")
PARA = "The old stone bridge arched over the river, its shadow trembling on the water. "
def filler(n, tag):
    ids = TOK.encode(tag + " " + PARA, add_special_tokens=False).ids
    buf = []
    while len(buf) < n:
        buf.extend(ids)
    return TOK.decode(buf[:n])
content = filler(16384, "SSD-FIXED-A.") + "\n\nReply with exactly SSD_TEST_OK."
payload = {"model": "Qwen3.8-27B", "messages": [{"role": "user", "content": content}],
           "max_tokens": 32, "stream": False, "temperature": 0.0,
           "chat_template_kwargs": {"enable_thinking": False}}
req = urllib.request.Request(BASE + "/v1/chat/completions",
    data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
    headers={"Authorization": "Bearer " + KEY, "Content-Type": "application/json"})
t0 = time.monotonic()
with urllib.request.urlopen(req, timeout=900) as r:
    d = json.load(r)
total = time.monotonic() - t0
u = d.get("usage", {})
pd = u.get("prompt_tokens_details", {})
txt = (((d.get("choices") or [{}])[0].get("message") or {}).get("content") or "")
print(json.dumps({"tag": TAG, "total": round(total, 2), "prompt": u.get("prompt_tokens"),
                  "cached": pd.get("cached_tokens"), "md5": hashlib.md5(txt.encode()).hexdigest()[:12],
                  "text": txt.strip()[:60]}, ensure_ascii=False))
