#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""ab_r5_focus.py — 定向复测（r5 vs prod）：只跑 digits（计数类，输出可逐字节对齐），
tier 65536 / 131072，每档 cold+warm 各 3 次重复；末尾内存探针 200 请求（拆成 pass1/pass2
两段，用于区分"首段预热分配"与"稳态泄漏率"）。

设计要点：
- 三个 leg（prodA / r5 / prodC）用**同一套 prompt 文本**（同一 NONCE，脚本内固定），
  每个 rep 的文本各不相同 → leg 内每个 rep 都是冷预填（前缀缓存不命中），
  且跨 leg 输出 md5 可逐字节对照。
- thinking ON + reasoning_effort=medium、temp=0、max_tokens=256（口径与全量套件一致）。

用法: ab_r5_focus.py <base_url> <out.json> <tag> [reps]
"""
import json, sys, time, os, urllib.request, hashlib
from tokenizers import Tokenizer

BASE = (sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8081").rstrip("/")
OUT = sys.argv[2] if len(sys.argv) > 2 else "/home/ai-agent/builds/upgrade-test/ab-r5-focus.json"
TAG = sys.argv[3] if len(sys.argv) > 3 else "focus"
REPS = int(sys.argv[4]) if len(sys.argv) > 4 else 3
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
NONCE = "FOCUS5-20260916T0930"          # 固定：三个 leg 共用同一套文本
TIERS = [65536, 131072]


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
       "regime": "thinking=on, reasoning_effort=medium, temp=0, max_tokens=256; digits-only focus",
       "reps": REPS, "rows": [], "mem": None, "mem_pass2": None}


def save():
    json.dump(res, open(OUT, "w", encoding="utf-8"), ensure_ascii=False, indent=1)


def run(name, content, tier, phase, max_tokens=256, kind="digits"):
    est = ntok(content)
    r = chat_stream(content, 0.0, max_tokens)
    r.update({"name": name, "tier": tier, "kind": kind, "phase": phase, "ptok_est": est})
    res["rows"].append(r)
    print("%-26s tier=%-7d %-6s ptok=%-7d ttft=%-9s decode=%-7s ctok=%-5d finish=%-6s md5=%s %s" % (
        name, tier, phase, est, r["ttft"], r["decode_tps"], r["ctok"], r["finish"], r["md5"],
        ("ERR " + r["err"]) if r["err"] else ""), flush=True)
    save()
    time.sleep(1)
    return r


# ---------- warmup (discarded) ----------
run("warm_2k_digits", filler(2000, NONCE + " warm a") + "\n\nCount from 1 to 50, one number per line.",
    2048, "warmup", 64)

# ---------- focused sweep: 3 reps x (64K,128K) x (cold,warm) ----------
for tier in TIERS:
    for rep in range(1, REPS + 1):
        tag = "%s digits %d rep%d." % (NONCE, tier, rep)          # 每 rep 独立前缀 → 冷预填
        content = filler(tier, tag) + "\n\nCount from 1 to 200, one number per line, no other text."
        run("t%d_digits_cold_r%d" % (tier, rep), content, tier, "cold")
        run("t%d_digits_warm_r%d" % (tier, rep), content, tier, "warm")   # 同文 → 命中前缀缓存

# ---------- memory probe: 200 short requests, pass1/pass2 split ----------
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
            if ("--port\x00" + port) in cmd:
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
print("memory probe pid =", pid, flush=True)
if pid:
    samples = []
    small = filler(1200, "MEM " + TAG + " " + NONCE + ".")
    for i in range(200):
        chat_stream(small, 0.0, 32, timeout=600)
        rss = rss_kb(pid)
        if rss:
            samples.append(rss)
        if (i + 1) % 50 == 0:
            print("  mem %3d/200 rss=%.1f MB" % (i + 1, rss / 1024.0), flush=True)
    if samples:
        n = len(samples)
        def seg(a, b, label):
            s = samples[a:b]
            return {"n": len(s), "start_mb": round(s[0] / 1024.0, 1), "end_mb": round(s[-1] / 1024.0, 1),
                    "growth_mb": round((s[-1] - s[0]) / 1024.0, 1),
                    "kb_per_req": round((s[-1] - s[0]) / float(len(s)), 1)}
        res["mem"] = seg(0, min(100, n), "pass1")
        res["mem_pass2"] = seg(min(100, n), n, "pass2") if n > 120 else None
        print("MEMPROBE pass1", json.dumps(res["mem"]), flush=True)
        print("MEMPROBE pass2", json.dumps(res["mem_pass2"]), flush=True)

res["done"] = time.strftime("%F %T")
save()
print("AB_R5_FOCUS done saved=%s rows=%d" % (OUT, len(res["rows"])), flush=True)
