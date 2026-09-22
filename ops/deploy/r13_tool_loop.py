#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""r13_tool_loop.py BASE — 工具调用回环探针（3 场景）。
S1 两轮回环: tool_calls → 回灌 tool 结果 → 终答（含数值）
S2 不该调用: 普通算术问题 + 无关工具 → 不得误触发 tool_calls
S3 流式工具: stream=true + tool_choice=auto → SSE 中应出现 tool_calls delta
"""
import json, sys, urllib.request, urllib.error

BASE = sys.argv[1].rstrip('/')
KEY = [l.split('=', 1)[1].strip().strip('"').strip("'")
       for l in open('/home/ai-agent/qwen38-0.2x.env', encoding='utf-8')
       if l.startswith('VLLM_API_KEY=')][0]
H = {'Authorization': 'Bearer ' + KEY, 'Content-Type': 'application/json'}
WEATHER_TOOL = {"type": "function", "function": {
    "name": "get_weather", "description": "Get weather for a city",
    "parameters": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}}}

def post(payload, stream=False, timeout=300):
    req = urllib.request.Request(BASE + '/v1/chat/completions',
                                 data=json.dumps(payload, ensure_ascii=False).encode('utf-8'),
                                 headers=H)
    return urllib.request.urlopen(req, timeout=timeout)

fails = 0

# ---- S1 两轮回环 ----
p1 = {"model": "Qwen3.8-27B", "messages": [{"role": "user", "content": "北京今天天气怎么样？用工具查。"}],
      "max_tokens": 300, "tools": [WEATHER_TOOL], "tool_choice": "auto",
      "chat_template_kwargs": {"enable_thinking": False}}
r1 = json.loads(post(p1).read().decode())["choices"][0]
m1 = r1.get("message") or {}
tc1 = m1.get("tool_calls") or []
ok_call = bool(tc1) and tc1[0]["function"]["name"] == "get_weather"
city_ok = False
if ok_call:
    try:
        city_ok = "北京" in json.loads(tc1[0]["function"]["arguments"]).get("city", "") or \
                  "beijing" in json.loads(tc1[0]["function"]["arguments"]).get("city", "").lower()
    except Exception:
        city_ok = False
print(f"[S1a] tool_call={ok_call} name={tc1[0]['function']['name'] if tc1 else None} args={tc1[0]['function']['arguments'] if tc1 else None} city_ok={city_ok} finish={r1.get('finish_reason')}")
fails += 0 if (ok_call and city_ok) else 1

if ok_call:
    msgs = p1["messages"] + [{"role": "assistant", "content": "", "tool_calls": tc1},
                             {"role": "tool", "tool_call_id": tc1[0].get("id", "call_1"),
                              "content": "晴，24摄氏度，微风"}]
    p2 = {"model": "Qwen3.8-27B", "messages": msgs, "max_tokens": 300,
          "tools": [WEATHER_TOOL], "tool_choice": "auto",
          "chat_template_kwargs": {"enable_thinking": False}}
    r2 = json.loads(post(p2).read().decode())["choices"][0]
    m2 = r2.get("message") or {}
    txt = m2.get("content") or ""
    ok2 = ("24" in txt) and (not m2.get("tool_calls"))
    print(f"[S1b] finish={r2.get('finish_reason')} tool_calls_again={bool(m2.get('tool_calls'))} mentions24={'24' in txt} text={txt.strip()[:60]!r}")
    fails += 0 if ok2 else 1
else:
    print("[S1b] SKIP (S1a 未触发工具)")
    fails += 1

# ---- S2 不该误调用 ----
p3 = {"model": "Qwen3.8-27B", "messages": [{"role": "user", "content": "3 乘以 7 等于多少？直接回答数字。"}],
      "max_tokens": 200, "tools": [WEATHER_TOOL], "tool_choice": "auto",
      "chat_template_kwargs": {"enable_thinking": False}}
r3 = json.loads(post(p3).read().decode())["choices"][0]
m3 = r3.get("message") or {}
t3 = m3.get("content") or ""
ok3 = (not m3.get("tool_calls")) and ("21" in t3)
print(f"[S2] tool_calls={bool(m3.get('tool_calls'))} has21={'21' in t3} text={t3.strip()[:50]!r}")
fails += 0 if ok3 else 1

# ---- S3 流式工具 ----
p4 = {"model": "Qwen3.8-27B", "messages": [{"role": "user", "content": "上海天气如何？用工具。"}],
      "max_tokens": 300, "tools": [WEATHER_TOOL], "tool_choice": "auto", "stream": True,
      "chat_template_kwargs": {"enable_thinking": False}}
got_tc_delta, got_text, finish = False, "", None
try:
    resp = post(p4, stream=True)
    for raw in resp:
        line = raw.decode('utf-8', 'ignore').strip()
        if not line.startswith('data:'):
            continue
        body = line[5:].strip()
        if body == '[DONE]':
            break
        try:
            d = json.loads(body)
        except Exception:
            continue
        ch = (d.get("choices") or [{}])[0]
        dl = ch.get("delta") or {}
        if dl.get("tool_calls"):
            got_tc_delta = True
        if dl.get("content"):
            got_text += dl["content"]
        if ch.get("finish_reason"):
            finish = ch["finish_reason"]
    print(f"[S3] stream_tool_calls={got_tc_delta} finish={finish} text_len={len(got_text)}")
    fails += 0 if got_tc_delta else 1
except Exception as e:
    print(f"[S3] STREAM_FAIL {e!r}")
    fails += 1

print(f"TOOL_LOOP_FAILS={fails}")
print("TOOL_LOOP_OK" if fails == 0 else "TOOL_LOOP_INCOMPLETE")
