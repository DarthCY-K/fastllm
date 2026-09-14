# -*- coding: utf-8 -*-
"""AB6: r2-default stabilization round.
- 5x cold 31K prefills to trace transient -> steady state
- decode samples early (post-warmup) and late (steady)
- q1 prose divergence re-test: SAME prompt twice in one process (md5 reproducibility)
"""
import json, sys, time, urllib.request, hashlib, re

BASE = sys.argv[1].rstrip("/")
OUT = sys.argv[2]
KEY = [l.split("=", 1)[1].strip().strip('"').strip("'")
       for l in open("/home/ai-agent/qwen38-0.2x.env", encoding="utf-8")
       if l.startswith("VLLM_API_KEY=")][0]
from tokenizers import Tokenizer
TOK = Tokenizer.from_file(
    "/home/ai-agent/fastllm-video-repro/models/nerkyor/Qwen3.8-27B-EfficientThink-FP8-lm/tokenizer.json")
PARA = ("The old stone bridge arched over the river, its shadow trembling on the water. "
        "Lanterns swayed along the alley, and somewhere a bamboo flute practiced the same "
        "gentle phrase, over and over, until the night learned it by heart. ")

def filler(n, tag):
    ids = TOK.encode(tag + " " + PARA, add_special_tokens=False).ids
    buf = []
    while len(buf) < n:
        buf.extend(ids)
    return TOK.decode(buf[:n])

def call(messages, temperature, max_tokens, timeout=900):
    payload = {"model": "Qwen3.8-27B-W8A16", "messages": messages,
               "max_tokens": max_tokens, "stream": True, "temperature": temperature,
               "chat_template_kwargs": {"enable_thinking": False}}
    if temperature > 0:
        payload["top_p"] = 0.95
    req = urllib.request.Request(BASE + "/v1/chat/completions",
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        headers={"Authorization": "Bearer " + KEY, "Content-Type": "application/json"})
    t0 = time.monotonic(); ttft = None; parts = []; fin = None
    with urllib.request.urlopen(req, timeout=timeout) as r:
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
            ch = (j.get("choices") or [{}])[0]; d = ch.get("delta") or {}
            piece = (d.get("content") or "") + (d.get("reasoning_content") or "")
            if piece:
                if ttft is None:
                    ttft = time.monotonic() - t0
                parts.append(piece)
            if ch.get("finish_reason"):
                fin = ch.get("finish_reason")
    total = time.monotonic() - t0
    text = "".join(parts)
    ctok = len(TOK.encode(text, add_special_tokens=False).ids)
    nums = [int(x) for x in re.findall(r"\b\d+\b", text)]
    c = {"ttft": round(ttft or -1, 3), "total": round(total, 3), "ctok": ctok,
         "finish": fin, "md5": hashlib.md5(text.encode()).hexdigest()[:12],
         "tail_nums": nums[-205:], "last": text[-40:].replace("\n", " ")}
    return c, text

res = {"tag": "AB6", "base": BASE, "when": time.strftime("%F %T"), "cases": []}

def run(name, content, temperature=0.0, max_tokens=1000):
    ptok = len(TOK.encode(content, add_special_tokens=False).ids)
    try:
        c, _ = call([{"role": "user", "content": content}], temperature, max_tokens)
    except Exception as e:
        c = {"error": repr(e)[:220]}
    c.update({"name": name, "ptok_est": ptok})
    res["cases"].append(c)
    print(name, json.dumps(c, ensure_ascii=False), flush=True)
    time.sleep(1)

run("w2k", filler(2000, "Warmup pass.") + "\n\nReply with exactly W2K_OK.", 0.0, 64)
run("d200_e", "Count from 1 to 200, one number per line, no other text.", 0.0, 2000)
run("d200_e2", "Note 2. Count from 1 to 200, one number per line, no other text.", 0.0, 2000)
for i in range(1, 6):
    run("c32_r%d" % i,
        filler(32000, "Cold pass %d." % i) + "\n\nNow count from 1 to 100, one number per line, no other text.",
        0.0, 1000)
run("d200_s1", "Steady 1. Count from 1 to 200, one number per line, no other text.", 0.0, 2000)
run("d200_s2", "Steady 2. Count from 1 to 200, one number per line, no other text.", 0.0, 2000)

mt = []
q1 = filler(20000, "Market pass.") + "\n\nWrite a vivid 300-word paragraph about a night market."
for k in (1, 2):
    try:
        c1, o1 = call([{"role": "user", "content": q1}], 0.0, 600)
        c2, _ = call([{"role": "user", "content": q1},
                      {"role": "assistant", "content": o1},
                      {"role": "user", "content": "Now count from 1 to 50, one number per line, no other text."}], 0.0, 1000)
        mt.append({"pair": k, "q1": {kk: c1[kk] for kk in ("ttft", "total", "ctok", "md5")},
                   "q2": {kk: c2[kk] for kk in ("ttft", "total", "ctok", "md5")}})
        print("mt_pair%d" % k, json.dumps(mt[-1], ensure_ascii=False), flush=True)
    except Exception as e:
        mt.append({"pair": k, "error": repr(e)[:200]})
    time.sleep(1)

res["mt"] = mt
json.dump(res, open(OUT, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
print("SAVED", OUT, flush=True)
