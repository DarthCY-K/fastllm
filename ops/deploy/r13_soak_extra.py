#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""r13_soak_extra.py BASE — 并发突发 + 前缀复用 两腿（配合 r13_soak.sh）。
- burst: 3 路并发相同短视频，检查三类一致性（同一提示词在多路并发下答案 md5 一致）
- reuse: 同一 6K 前缀发 2 次，比较第 2 次的 ttft（前缀缓存命中应显著更快）
"""
import sys, json, time, hashlib, threading, urllib.request

BASE = sys.argv[1].rstrip('/') if len(sys.argv) > 1 else 'http://127.0.0.1:8080'
KEY = [l.split('=', 1)[1].strip().strip('"').strip("'")
       for l in open('/home/ai-agent/qwen38-0.2x.env', encoding='utf-8')
       if l.startswith('VLLM_API_KEY=')][0]

def call(messages, max_tokens=64, timeout=600):
    body = {'model': 'Qwen3.8-27B', 'messages': messages, 'max_tokens': max_tokens,
            'temperature': 0, 'stream': False}
    req = urllib.request.Request(BASE + '/v1/chat/completions', data=json.dumps(body).encode(),
                                 headers={'Authorization': 'Bearer ' + KEY,
                                          'Content-Type': 'application/json'})
    t0 = time.time()
    r = json.loads(urllib.request.urlopen(req, timeout=timeout).read().decode())
    dt = time.time() - t0
    txt = r['choices'][0]['message'].get('content') or ''
    return txt, dt

PARA = ("The old stone bridge arched over the river, its shadow trembling on the water. "
        "Lanterns swayed along the alley, and somewhere a bamboo flute practiced the same "
        "gentle phrase, over and over, until the night learned it by heart. ")

# --- leg 1: 并发突发（3 路，同提示词，短输出） ---
prompt = "请把下列序列原样回显，不要解释：" + " ".join(f"{i:03d}" for i in range(1, 21))
res = {}
def worker(i):
    t, dt = call([{'role': 'user', 'content': prompt}], max_tokens=160)
    res[i] = (hashlib.md5(t.encode()).hexdigest()[:12], round(dt, 2), len(t))
ths = [threading.Thread(target=worker, args=(i,)) for i in range(3)]
t0 = time.time(); [t.start() for t in ths]; [t.join() for t in ths]
wall = round(time.time() - t0, 2)
hashes = {v[0] for v in res.values()}
print(f"[burst] wall={wall}s md5s={sorted(hashes)} uniq={len(hashes)} per-request={ {k: v[1:] for k, v in sorted(res.items())} }")

# --- leg 2: 前缀复用（6K 前缀，同一请求发两次） ---
import re
def filler(n):
    ids = PARA
    s = ("请阅读以下长文并记住首行编号。\n" + "编号A-778812 起始。\n")
    while len(s) < n * 4:
        s += PARA
    return s[:n * 4] + "\n问：开头那行编号是什么？只回答编号。"
msg = [{'role': 'user', 'content': filler(6000)}]
t1, d1 = call(msg, max_tokens=32)
t2, d2 = call(msg, max_tokens=32)
print(f"[reuse] run1={d1:.2f}s run2={d2:.2f}s speedup={d1/max(d2,1e-6):.2f}x ans1={t1.strip()[:24]!r} ans2={t2.strip()[:24]!r} same={t1.strip()==t2.strip()}")
print("SOAK_EXTRA_OK")
