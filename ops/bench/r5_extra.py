#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""r5 extra probes:
   (1) PR #663 功能验证：role=tool 且 content 为 JSON 对象 -> 应 200（未打补丁时 400 Complex input not supported yet）
   (2) reasoning_effort 门控：medium -> 200，high -> 400（本构建只接受 low/medium/xhigh）
   (3) /v1/models 列表
用法: r5_extra.py <base_url> <out.json> [tag]
"""
import json, sys, urllib.request, urllib.error

BASE = sys.argv[1].rstrip("/")
OUT = sys.argv[2]
TAG = sys.argv[3] if len(sys.argv) > 3 else "r5"
KEY = [l.split("=", 1)[1].strip().strip('"').strip("'")
       for l in open("/home/ai-agent/qwen38-0.2x.env", encoding="utf-8")
       if l.startswith("VLLM_API_KEY=")][0]
MODEL = "Qwen3.8-27B-W8A16"


def post(body, timeout=240):
    req = urllib.request.Request(
        BASE + "/v1/chat/completions", data=json.dumps(body).encode(),
        headers={"Authorization": "Bearer " + KEY, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:
        return -1, repr(e)


res = {"tag": TAG, "base": BASE}

# (1) tool-content object (PR #663)
body = {
    "model": MODEL,
    "messages": [
        {"role": "user", "content": "what is the weather? call the tool"},
        {"role": "assistant", "content": "", "tool_calls": [
            {"id": "c1", "type": "function",
             "function": {"name": "get_weather", "arguments": '{"city":"Beijing"}'}}]},
        {"role": "tool", "tool_call_id": "c1",
         "content": {"city": "Beijing", "temp_c": 21, "sky": "clear"}},
    ],
    "max_tokens": 64, "temperature": 0,
    "chat_template_kwargs": {"enable_thinking": False},
}
code, txt = post(body)
res["tool_content_object"] = {"http": code, "snippet": txt[:220]}

# (2) reasoning_effort gate
for eff in ("medium", "high"):
    body = {"model": MODEL, "messages": [{"role": "user", "content": "reply ok"}],
            "max_tokens": 16, "temperature": 0, "reasoning_effort": eff}
    code, txt = post(body)
    res["effort_" + eff] = {"http": code, "snippet": txt[:180]}

# (3) models
try:
    req = urllib.request.Request(BASE + "/v1/models", headers={"Authorization": "Bearer " + KEY})
    with urllib.request.urlopen(req, timeout=30) as r:
        res["models"] = {"http": r.status, "snippet": r.read().decode("utf-8", "replace")[:300]}
except urllib.error.HTTPError as e:
    res["models"] = {"http": e.code}

json.dump(res, open(OUT, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
print(json.dumps(res, ensure_ascii=False)[:1400])
