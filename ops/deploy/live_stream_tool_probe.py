#!/usr/bin/env python3
"""Live streaming tool-call probe against the production FastLLM endpoint.

Reproduces the client shape Pi uses (stream=True + tools) and checks the
whole SSE path: tool_calls deltas, accumulated arguments, finish_reason,
and absence of an embedded error payload.
"""
import json
import sys
import urllib.request

BASE = sys.argv[1].rstrip("/") if len(sys.argv) > 1 else "http://127.0.0.1:8080"
KEY = [line.split("=", 1)[1].strip().strip('"').strip("'")
       for line in open("/home/ai-agent/qwen38-0.2x.env", encoding="utf-8")
       if line.startswith("VLLM_API_KEY=")][0]

payload = {
    "model": "Qwen3.8-27B-W8A16",
    "stream": True,
    "messages": [{
        "role": "user",
        "content": "Create a small file with the write tool: path probe.txt, "
                   "content 'hello world'.",
    }],
    "tools": [{
        "type": "function",
        "function": {
            "name": "write",
            "description": "Create or overwrite a UTF-8 text file.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string"},
                    "content": {"type": "string"},
                },
                "required": ["path", "content"],
                "additionalProperties": False,
            },
        },
    }],
    "tool_choice": "required",
    "max_tokens": 400,
    "chat_template_kwargs": {"enable_thinking": False},
}

request = urllib.request.Request(
    BASE + "/v1/chat/completions",
    data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
    headers={"Authorization": "Bearer " + KEY,
             "Content-Type": "application/json"})

chunks = 0
tool_delta_chunks = 0
name = ""
arguments = ""
finish_reason = None
error = None
done = False

with urllib.request.urlopen(request, timeout=600) as response:
    for raw in response:
        line = raw.decode("utf-8", "replace").strip()
        if not line.startswith("data:"):
            continue
        data = line[len("data:"):].strip()
        if data == "[DONE]":
            done = True
            continue
        chunks += 1
        event = json.loads(data)
        if event.get("error"):
            error = event["error"]
            continue
        choice = (event.get("choices") or [{}])[0]
        delta = choice.get("delta") or {}
        for call in delta.get("tool_calls") or []:
            tool_delta_chunks += 1
            function = call.get("function") or {}
            if function.get("name"):
                name = function["name"]
            if function.get("arguments"):
                arguments += function["arguments"]
        if choice.get("finish_reason"):
            finish_reason = choice["finish_reason"]

print("STREAM_PROBE chunks=%d tool_delta_chunks=%d done=%s finish=%s "
      "name=%s" % (chunks, tool_delta_chunks, done, finish_reason, name))
print("STREAM_PROBE arguments=%r" % arguments)
print("STREAM_PROBE error=%r" % (error,))

ok = (done and error is None and finish_reason == "tool_calls"
      and name == "write" and tool_delta_chunks > 0)
try:
    parsed = json.loads(arguments)
    ok = ok and parsed.get("path") == "probe.txt" and "hello" in parsed.get("content", "")
    print("STREAM_PROBE parsed=%s" % parsed)
except Exception as exc:  # noqa: BLE001
    ok = False
    print("STREAM_PROBE argument_parse_failed=%r" % exc)

print("STREAM_PROBE", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
