#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""AB r5 suite — same-window prod(8080) vs r5(8081) comparison.

Axes (per user protocol): context tiers 2048 / 65536 / 131072, each in cold
(unique filler, no prefix hit) and warm (identical repeat, prefix-cache restore)
form; content classes digits + prose (prose at 2048/65536 only); thinking ON with
reasoning_effort=medium (mandatory default regime). Then a memory-growth probe
(~100 short requests, /proc VmRSS sampling) to exercise upstream 74d363833.

Usage: ab_r5_suite.py <base_url> <out.json> <tag>
"""
import json, sys, time, os, urllib.request, urllib.error, hashlib
from tokenizers import Tokenizer

BASE = (sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8081").rstrip("/")
OUT = sys.argv[2] if len(sys.argv) > 2 else "/home/ai-agent/builds/upgrade-test/ab-r5.json"
TAG = sys.argv[3] if len(sys.argv) > 3 else "ab"
KEY = [l.split("=", 1)[1].strip().strip('"').strip("'")
       for l in open("/home/ai-agent/qwen38-0.2x.env", encoding="utf-8")
       if l.startswith("VLLM_API_KEY=")][0]
MODEL = "Qwen3.8-27B-W8A16"
THINK = {"enable_thinking": True, "reasoning_effort": "medium"}
TOK = Tokenizer.from_file(
    "/home/ai-agent/fastllm-video-repro/models/nerkyor/Qwen3.8-27B-EfficientThink-FP8-lm/tokenizer.json")
PARA = ("The old stone bridge arched over the river, its shadow trembling on the water. "
        "Lanterns swayed along the alley, and somewhere a bamboo flute practiced the same "
        "gentle phrase, over and over, until the night learned it by heart. ")
NONCE = str(int(time.time()))

def filler(n, tag):
    ids = TOK.encode(tag + " " + PARA, add_special_tokens=False).ids
    buf = []
    while len(buf) < n:
        buf.extend(ids)
    return TOK.decode(buf[:n])

def ntok(s):
    return len(TOK.encode(s, add_special_tokens=False).ids)

def chat_stream(content, temperature=0.0, max_tokens=256, timeout=3600):
    payload = {"model": MODEL, "messages": [{"role": "user", "content": content}],
               "max_tokens": max_tokens, "stream": True, "temperature": temperature,
               "chat_template_kwargs": THINK}
    req = urllib.request.Request(BASE + "/v1/chat/completions",
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        headers={"Authorization": "Bearer " + KEY, "Content-Type": "application/json"})
    t0 = time.monotonic(); ttft = None; parts = []; fin = None; err = None
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            for raw in r:
                line = raw.decode("utf-8", "ignore").strip()
                if not line.startswith("data: "):
                    continue
                b = line[6:]
                if b == "[DONE]":
                    break
                try:
                    j = json.loads(b)
                except Exception:
                    continue
                ch = (j.get("choices") or [{}])[0]
                d = ch.get("delta") or {}
                piece = (d.get("content") or "") + (d.get("reasoning_content") or "")
                if piece:
                    if ttft is None:
                        ttft = time.monotonic() - t0
                    parts.append(piece)
                if ch.get("finish_reason"):
                    fin = ch.get("finish_reason")
    except Exception as e:
        err = repr(e)[:200]
    total = time.monotonic() - t0
    text = "".join(parts)
    ctok = ntok(text)
    return {"ttft": round(ttft or -1, 3), "total": round(total, 3), "ctok": ctok,
            "decode_tps": round(ctok / max(total - (ttft or 0), 1e-6), 1),
            "finish": fin, "md5": hashlib.md5(text.encode()).hexdigest()[:12],
            "err": err}

res = {"tag": TAG, "when": time.strftime("%F %T"), "base": BASE, "nonce": NONCE,
       "regime": "thinking=on, reasoning_effort=medium, temp=0, max_tokens=256",
       "rows": [], "mem": None}

def save():
    json.dump(res, open(OUT, "w", encoding="utf-8"), ensure_ascii=False, indent=1)

def run(name, content, tier, kind, phase, max_tokens=256):
    est = ntok(content)
    r = chat_stream(content, 0.0, max_tokens)
    r.update({"name": name, "tier": tier, "kind": kind, "phase": phase, "ptok_est": est})
    res["rows"].append(r)
    print("%-22s tier=%-7s %-8s ptok=%-7d ttft=%-8s decode=%-7s ctok=%-5d finish=%-6s md5=%s %s" % (
        name, tier, phase, est, r["ttft"], r["decode_tps"], r["ctok"], r["finish"], r["md5"],
        ("ERR " + r["err"]) if r["err"] else ""), flush=True)
    save()
    time.sleep(1)
    return r

# ---------- warmup (discarded; pays stack cold-start transient) ----------
run("warm_2k", filler(2000, "WARM " + NONCE + " a") + "\n\nCount from 1 to 50, one number per line.", 2048, "digits", "warmup", 64)
run("warm_32k", filler(32000, "WARM " + NONCE + " b") + "\n\nReply with exactly WARM_OK.", 32768, "prose", "warmup", 32)

# ---------- tier sweep ----------
TIERS = [(2048, ("digits", "prose")), (65536, ("digits", "prose")), (131072, ("digits",))]
for tier, kinds in TIERS:
    for kind in kinds:
        tag = "ABR3 %s %s %d %s." % (TAG, kind, tier, NONCE)
        if kind == "digits":
            instr = "\n\nCount from 1 to 200, one number per line, no other text."
        else:
            instr = "\n\nContinue this scene in English, vivid and flowing, two to three paragraphs."
        content = filler(tier, tag) + instr
        run("t%d_%s_cold" % (tier, kind), content, tier, kind, "cold")
        run("t%d_%s_warm" % (tier, kind), content, tier, kind, "warm")

# ---------- memory-growth probe (upstream 74d363833) ----------
def server_pid():
    port = BASE.rsplit(":", 1)[-1]
    for pid_dir in os.listdir("/proc"):
        if not pid_dir.isdigit():
            continue
        try:
            cmd = open("/proc/%s/cmdline" % pid_dir, "rb").read().decode("utf-8", "ignore")
        except Exception:
            continue
        if "ftllm.cli" in cmd or ("ftllm" in cmd and "server" in cmd):
            try:
                env = open("/proc/%s/environ" % pid_dir, "rb").read().decode("utf-8", "ignore")
            except Exception:
                env = ""
            if ("--port\x00" + port) in cmd or ("--port\x00" + port + "\x00") in cmd:
                return int(pid_dir)
    return None

def rss_kb(pid):
    try:
        for line in open("/proc/%d/status" % pid):
            if line.startswith("VmRSS:"):
                return int(line.split()[1])
    except Exception:
        pass
    return None

pid = server_pid()
print("memory probe: server pid =", pid, flush=True)
if pid:
    samples = []
    small = filler(1200, "MEM " + TAG + " " + NONCE + ".")
    for i in range(100):
        chat_stream(small, 0.0, 32, timeout=600)
        rss = rss_kb(pid)
        if rss:
            samples.append(rss)
        if (i + 1) % 20 == 0:
            print("  mem %3d/100 rss=%.1f MB" % (i + 1, rss / 1024.0), flush=True)
    if samples:
        n = len(samples)
        res["mem"] = {"pid": pid, "n": n, "rss_start_mb": round(samples[0] / 1024.0, 1),
                      "rss_mid_mb": round(samples[n // 2] / 1024.0, 1),
                      "rss_end_mb": round(samples[-1] / 1024.0, 1),
                      "growth_mb": round((samples[-1] - samples[0]) / 1024.0, 1),
                      "growth_kb_per_req": round((samples[-1] - samples[0]) / float(n), 1)}
        print("MEMPROBE", json.dumps(res["mem"]), flush=True)

res["done"] = time.strftime("%F %T")
save()
print("AB_R3_SUITE done saved=%s rows=%d" % (OUT, len(res["rows"])), flush=True)
