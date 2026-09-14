# -*- coding: utf-8 -*-
"""tool_probe2.py BASE — 工具调用回环探针（可指定地址）。"""
import json, sys, urllib.request
BASE = sys.argv[1].rstrip("/")
KEY = [l.split("=", 1)[1].strip().strip('"').strip("'") for l in open("/home/ai-agent/qwen38-0.2x.env", encoding="utf-8") if l.startswith("VLLM_API_KEY=")][0]
payload = {
    "model": "Qwen3.8-27B-W8A16",
    "messages": [{"role": "user", "content": "What is the weather in Beijing? Use the tool."}],
    "max_tokens": 300,
    "tools": [{"type": "function", "function": {"name": "get_weather", "description": "Get weather for a city", "parameters": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}}}],
    "tool_choice": "required",
    "chat_template_kwargs": {"enable_thinking": False},
}
req = urllib.request.Request(BASE + "/v1/chat/completions",
    data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
    headers={"Authorization": "Bearer " + KEY, "Content-Type": "application/json"})
with urllib.request.urlopen(req, timeout=180) as r:
    b = json.loads(r.read().decode("utf-8"))
ch = b["choices"][0]
m = ch.get("message") or {}
tc = m.get("tool_calls")
name = tc[0]["function"]["name"] if tc else None
try:
    args = json.loads(tc[0]["function"]["arguments"]) if tc else None
except Exception:
    args = "PARSE_FAIL"
print("TOOL_PROBE finish=%s has_tool_calls=%s name=%s args=%s" % (ch.get("finish_reason"), bool(tc), name, args))
