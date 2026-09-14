# -*- coding: utf-8 -*-
"""needle_probe.py BASE [depth_tokens] [total_tokens] — 1M 长上下文针测（>262144 走 YaRN 外推）。
针位于 depth 处，问句在尾部；检查回答包含密码。"""
import json, sys, time, urllib.request

BASE = sys.argv[1].rstrip("/")
DEPTH = int(sys.argv[2]) if len(sys.argv) > 2 else 120000
TOTAL = int(sys.argv[3]) if len(sys.argv) > 3 else 320000
KEY = [l.split("=", 1)[1].strip().strip('"').strip("'")
       for l in open("/home/ai-agent/qwen38-0.2x.env", encoding="utf-8")
       if l.startswith("VLLM_API_KEY=")][0]
from tokenizers import Tokenizer
TOK = Tokenizer.from_file(
    "/home/ai-agent/fastllm-video-repro/models/nerkyor/Qwen3.8-27B-EfficientThink-FP8-lm/tokenizer.json")
PARA = ("The old stone bridge arched over the river, its shadow trembling on the water. "
        "Lanterns swayed along the alley, and somewhere a bamboo flute practiced the same "
        "gentle phrase, over and over, until the night learned it by heart. ")
NEEDLE = "\n\n【重要备忘】系统保险柜的验证码是 X9J7-QUARTZ-3312，请牢记。\n\n"

def filler(n, tag):
    ids = TOK.encode(tag + " " + PARA, add_special_tokens=False).ids
    buf = []
    while len(buf) < n:
        buf.extend(ids)
    return TOK.decode(buf[:n])

prompt = filler(DEPTH, "NEEDLE-A.") + NEEDLE + filler(TOTAL - DEPTH, "NEEDLE-B.") + \
    "\n\n根据上文的【重要备忘】，系统保险柜的验证码是什么？只回答验证码本身，不要其他文字。"
ptok = len(TOK.encode(prompt, add_special_tokens=False).ids)
print("prompt_tokens=", ptok, "depth=", DEPTH, flush=True)

payload = {"model": "Qwen3.8-27B-W8A16", "messages": [{"role": "user", "content": prompt}],
           "max_tokens": 64, "stream": True, "temperature": 0.0,
           "chat_template_kwargs": {"enable_thinking": False}}
req = urllib.request.Request(BASE + "/v1/chat/completions",
    data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
    headers={"Authorization": "Bearer " + KEY, "Content-Type": "application/json"})
t0 = time.monotonic(); ttft = None; parts = []
with urllib.request.urlopen(req, timeout=1800) as r:
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
        d = (j.get("choices") or [{}])[0].get("delta") or {}
        p = (d.get("content") or "") + (d.get("reasoning_content") or "")
        if p:
            if ttft is None:
                ttft = time.monotonic() - t0
            parts.append(p)
total = time.monotonic() - t0
text = "".join(parts)
print(json.dumps({"ttft": round(ttft or -1, 1), "total": round(total, 1),
                  "answer": text.strip()[:120],
                  "found": "X9J7-QUARTZ-3312" in text}, ensure_ascii=False))
