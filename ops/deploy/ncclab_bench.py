#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ncclab_bench.py BASE TAG — NCCL 会合自旋 A/B 的量测盘。
输出（stdout，单行 JSON + 易读行）：
  decode_runs: 5×（prompt 固定，max_tokens=512，temp=0）→ 每跑 decode t/s（用 usage 计数算）
  short_burst: 20×（max_tokens=32）→ 每跑墙钟 + 总计
  ttft: 首跑 ttft
"""
import json, sys, time, urllib.request

BASE = sys.argv[1].rstrip('/')
TAG = sys.argv[2] if len(sys.argv) > 2 else 'x'
KEY = [l.split('=', 1)[1].strip().strip('"').strip("'")
       for l in open('/home/ai-agent/qwen38-0.2x.env', encoding='utf-8')
       if l.startswith('VLLM_API_KEY=')][0]
H = {'Authorization': 'Bearer ' + KEY, 'Content-Type': 'application/json'}

def _model_id():
    req = urllib.request.Request(BASE + '/v1/models', headers=H)
    d = json.loads(urllib.request.urlopen(req, timeout=30).read().decode())
    return d['data'][0]['id']

MODEL = _model_id()
print(f"[{TAG}] model_id={MODEL}")

def call(prompt, max_tokens, timeout=600):
    body = {"model": MODEL, "messages": [{"role": "user", "content": prompt}],
            "max_tokens": max_tokens, "temperature": 0, "stream": False,
            "chat_template_kwargs": {"enable_thinking": False}}
    req = urllib.request.Request(BASE + '/v1/chat/completions',
                                 data=json.dumps(body, ensure_ascii=False).encode('utf-8'), headers=H)
    t0 = time.time()
    d = json.loads(urllib.request.urlopen(req, timeout=timeout).read().decode())
    wall = time.time() - t0
    u = d.get('usage') or {}
    return wall, u

PROMPT = ("请从 1 数到 200，每行一个数字，不要任何解释。")
decodes = []
ttft = None
for i in range(5):
    wall, u = call(PROMPT, 512)
    ct = u.get('completion_tokens', 0)
    pt = u.get('prompt_tokens', 0)
    tps = ct / wall if wall > 0 else 0
    decodes.append(round(tps, 2))
    if i == 0:
        ttft = round(wall, 2)
    print(f"[{TAG}] decode#{i+1} wall={wall:.2f}s ct={ct} pt={pt} tps={tps:.2f}")

burst = []
for i in range(20):
    wall, u = call("只回答：好的", 32)
    burst.append(wall)
burst_sorted = sorted(burst)
print(f"[{TAG}] short_burst n=20 total={sum(burst):.2f}s mean={sum(burst)/len(burst)*1000:.0f}ms "
      f"p50={burst_sorted[10]*1000:.0f}ms min={burst_sorted[0]*1000:.0f}ms max={burst_sorted[-1]*1000:.0f}ms")
summary = {"tag": TAG, "decode_tps": decodes,
           "decode_mean": round(sum(decodes) / len(decodes), 3),
           "decode_min": min(decodes), "decode_max": max(decodes),
           "burst_mean_ms": round(sum(burst) / len(burst) * 1000, 1),
           "burst_p50_ms": round(burst_sorted[10] * 1000, 1),
           "burst_total_s": round(sum(burst), 2)}
print("BENCH_JSON " + json.dumps(summary, ensure_ascii=False))
