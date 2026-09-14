# -*- coding: utf-8 -*-
"""chunk_probe.py — 发一个 ~2.2K token 冷预填，用日志 seeded 行验证有效分块。
r2 默认（快照间隔 2 页）应为 chunk=256；r1 为 chunk=512。"""
import json, urllib.request, time

KEY = [l.split("=", 1)[1].strip().strip('"').strip("'")
       for l in open("/home/ai-agent/qwen38-0.2x.env", encoding="utf-8")
       if l.startswith("VLLM_API_KEY=")][0]
from tokenizers import Tokenizer
TOK = Tokenizer.from_file(
    "/home/ai-agent/fastllm-video-repro/models/nerkyor/Qwen3.8-27B-EfficientThink-FP8-lm/tokenizer.json")
para = "The old stone bridge arched over the river, its shadow trembling on the water. "
ids = TOK.encode("Switch probe. " + para, add_special_tokens=False).ids
buf = []
while len(buf) < 2200:
    buf.extend(ids)
text = TOK.decode(buf[:2200]) + "\n\nReply with exactly SWITCH_R2_OK."
body = {"model": "Qwen3.8-27B-W8A16", "messages": [{"role": "user", "content": text}],
        "max_tokens": 32, "temperature": 0, "stream": False,
        "chat_template_kwargs": {"enable_thinking": False}}
req = urllib.request.Request("http://127.0.0.1:8080/v1/chat/completions",
                             data=json.dumps(body).encode("utf-8"),
                             headers={"Authorization": "Bearer " + KEY,
                                      "Content-Type": "application/json"})
t0 = time.time()
with urllib.request.urlopen(req, timeout=300) as r:
    d = json.load(r)
print("probe http=%s %.1fs content=%r" % (r.status, time.time() - t0,
      d["choices"][0]["message"]["content"][:60]))
