#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""mmguard_smoke.py — 切换后最小验收：带 key 的一次真实短补全。
退出码 0 = HTTP 200 且 content 非空。"""
import json, sys, urllib.request, urllib.error

BASE = "http://127.0.0.1:8080"
MODEL = "Qwen3.8-27B-W8A16"
key = ""
for line in open("/home/ai-agent/qwen38-0.2x.env", encoding="utf-8"):
    line = line.strip()
    if line.startswith("VLLM_API_KEY="):
        key = line.split("=", 1)[1].strip().strip('"').strip("'")
        break
if not key:
    print("NO_KEY")
    sys.exit(2)

payload = {
    "model": MODEL,
    "messages": [{"role": "user", "content": "Reply with exactly MMGUARD_SMOKE_OK"}],
    "max_tokens": 32,
    "temperature": 0.0,
}
req = urllib.request.Request(
    BASE + "/v1/chat/completions",
    data=json.dumps(payload).encode("utf-8"),
    headers={"Content-Type": "application/json", "Authorization": "Bearer " + key},
)
try:
    with urllib.request.urlopen(req, timeout=600) as resp:
        body = json.loads(resp.read().decode("utf-8"))
        content = body["choices"][0]["message"].get("content") or ""
        print("HTTP 200 content=%r" % content[:80])
        sys.exit(0 if content.strip() else 3)
except urllib.error.HTTPError as e:
    print("HTTP", e.code, e.read()[:200])
    sys.exit(4)
except Exception as e:
    print("ERR", type(e).__name__, str(e)[:200])
    sys.exit(5)
