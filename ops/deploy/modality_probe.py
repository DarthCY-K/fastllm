#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""modality_probe.py — 校验 /v1/models 图片能力上报（input_modalities 含 image）。
退出码 0 = 含 image；3 = 不含；2 = 取不到 key；5 = 其他错误。"""
import json, sys, urllib.request, urllib.error

BASE = "http://127.0.0.1:8080"
key = ""
for line in open("/home/ai-agent/qwen38-0.2x.env", encoding="utf-8"):
    line = line.strip()
    if line.startswith("VLLM_API_KEY="):
        key = line.split("=", 1)[1].strip().strip('"').strip("'")
        break
if not key:
    print("NO_KEY")
    sys.exit(2)

req = urllib.request.Request(
    BASE + "/v1/models", headers={"Authorization": "Bearer " + key})
try:
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.loads(resp.read().decode("utf-8"))
except Exception as e:
    print("ERR", type(e).__name__, str(e)[:200])
    sys.exit(5)

m = data["data"][0]
im = m.get("input_modalities") or m.get("inputModalities") or []
print("model=%s input_modalities=%s" % (m.get("id"), im))
sys.exit(0 if "image" in im else 3)
