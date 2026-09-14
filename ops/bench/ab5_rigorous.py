# -*- coding: utf-8 -*-
"""AB5: rigorous rigorous A/B suite.

Design notes:
- Every request carries a unique tag so each measurement is on a COLD prompt
  (no cross-request prefix reuse), except the deliberate multi-turn probe.
- Count tasks at temperature 0 for deterministic outputs; md5 + number
  sequence recorded for cross-config equality checks.
- Server-side chunk lines are parsed offline per config to reconcile timing.

Cases (in order):
  w2k        : ~2K prefill warmup (also reveals effective chunk size in log)
  d200_exact : exact "count 1..200" anchor, identical across configs
  d200_r2/3  : tagged decode reps (cold)
  c32_r1..3  : ~32K unique cold prefills, count 1..100 tail  (THE prefill case)
  mt_q1/mt_q2: 20K prompt + 600-token generation, then continuation that
               reuses prompt+output (restore-length probe)
  tail40     : ~8.2K prompt whose tail chunk is ~40 tokens (per-token path)
"""
import json, sys, time, urllib.request, hashlib, re

BASE = sys.argv[1].rstrip("/")
OUT = sys.argv[2]
TAG = sys.argv[3] if len(sys.argv) > 3 else "run"
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
    c = {"ttft": round(ttft or -1, 3), "total": round(total, 3),
         "ctok": ctok, "tps_naive": round(ctok / max(total - (ttft or 0), 1e-6), 1),
         "finish": fin, "md5": hashlib.md5(text.encode()).hexdigest()[:12],
         "tail_nums": nums[-205:], "last": text[-40:].replace("\n", " ")}
    return c, text

res = {"tag": TAG, "base": BASE, "when": time.strftime("%F %T"), "cases": []}

def run(name, content, temperature, max_tokens, reps=1):
    for i in range(reps):
        ptok = len(TOK.encode(content, add_special_tokens=False).ids)
        try:
            c, _ = call([{"role": "user", "content": content}], temperature, max_tokens)
        except Exception as e:
            c = {"error": repr(e)[:220]}
        c.update({"name": name, "rep": i + 1, "ptok_est": ptok})
        res["cases"].append(c)
        print(name, i + 1, json.dumps(c, ensure_ascii=False), flush=True)
        time.sleep(1)

# 1) warmup (~2K prefill; chunk size visible in server log)
run("w2k", filler(2000, "Warmup pass.") + "\n\nReply with exactly W2K_OK.", 0.0, 64)
# 2) exact anchor (identical string on every config)
run("d200_exact", "Count from 1 to 200, one number per line, no other text.", 0.0, 2000)
# 3) tagged decode reps (cold prompts)
for i in (2, 3):
    run("d200_r%d" % i, "Note %d. Count from 1 to 200, one number per line, no other text." % i, 0.0, 2000)
# 4) cold 32K prefill reps (unique per rep)
for i in (1, 2, 3):
    run("c32_r%d" % i,
        filler(32000, "Cold pass %d." % i) + "\n\nNow count from 1 to 100, one number per line, no other text.",
        0.0, 1000)
# 5) multi-turn restore probe
mt = {}
try:
    q1 = filler(20000, "Market pass.") + "\n\nWrite a vivid 300-word paragraph about a night market."
    c1, o1 = call([{"role": "user", "content": q1}], 0.0, 600)
    mt["q1"] = {k: c1[k] for k in ("ttft", "total", "ctok", "finish", "md5")}
    q2 = [{"role": "user", "content": q1},
          {"role": "assistant", "content": o1},
          {"role": "user", "content": "Now count from 1 to 50, one number per line, no other text."}]
    c2, _ = call(q2, 0.0, 1000)
    mt["q2"] = {k: c2[k] for k in ("ttft", "total", "ctok", "finish", "md5", "tail_nums")}
    mt["q2"]["p1_chars"] = len(q1); mt["q2"]["o1_chars"] = len(o1)
except Exception as e:
    mt["error"] = repr(e)[:220]
res["mt"] = mt
print("mt", json.dumps(mt, ensure_ascii=False)[:600], flush=True)
# 6) tail-chunk probe (~8232 total tokens -> tail ~40 for both 512/256 chunking)
run("tail40", filler(8200, "Tail pass.") + "\n\nNow count from 1 to 100, one number per line, no other text.",
    0.0, 1000)

json.dump(res, open(OUT, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
print("SAVED", OUT, flush=True)
