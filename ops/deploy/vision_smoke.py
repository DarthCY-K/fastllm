#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""vision_smoke.py — 一次真实含图请求冒烟（复用 mmguard 证据图）。
退出码 0 = HTTP 200 且 content/reasoning_content 非空。"""
import base64, json, sys, urllib.request, urllib.error

BASE = "http://127.0.0.1:8080"
MODEL = "Qwen3.8-27B-W8A16"
IMG = "/home/ai-agent/builds/upgrade-test/wt-pooltrim/ops/evidence/mmguard-20260917/img_a.png"
key = ""
for line in open("/home/ai-agent/qwen38-0.2x.env", encoding="utf-8"):
    line = line.strip()
    if line.startswith("VLLM_API_KEY="):
        key = line.split("=", 1)[1].strip().strip('"').strip("'")
        break
if not key:
    print("NO_KEY")
    sys.exit(2)

with open(IMG, "rb") as fh:
    b64 = base64.b64encode(fh.read()).decode("ascii")

payload = {
    "model": MODEL,
    "messages": [{
        "role": "user",
        "content": [
            {"type": "text", "text": "用一句话简单描述这张图片（颜色/形状）。"},
            {"type": "image_url", "image_url": {"url": "data:image/png;base64," + b64}},
        ],
    }],
    "max_tokens": 512,
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
        msg = body["choices"][0]["message"]
        content = msg.get("content") or msg.get("reasoning_content") or ""
        print("HTTP 200 content=%r" % content[:200])
        sys.exit(0 if content.strip() else 3)
except urllib.error.HTTPError as e:
    print("HTTP", e.code, e.read()[:300])
    sys.exit(4)
except Exception as e:
    print("ERR", type(e).__name__, str(e)[:300])
    sys.exit(5)
