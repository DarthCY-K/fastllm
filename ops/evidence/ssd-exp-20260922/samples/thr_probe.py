#!/usr/bin/env python3
"""thr_probe.py — 零窗口诊断：采样引擎进程各线程 syscall/wchan/CPU，
定位「前缀缓存导出」那几秒时间花在哪。生产只读。

用法: thr_probe.py [总采样秒=28] [首发前置秒=2]
"""
import collections, json, os, subprocess, sys, threading, time

DUR = float(sys.argv[1]) if len(sys.argv) > 1 else 28.0
DELAY = float(sys.argv[2]) if len(sys.argv) > 2 else 2.0
IV = 0.004
LOG = "/home/ai-agent/fastllm-video-repro/results/server-prod.service.log"
sys.path.insert(0, "/home/ai-agent/bench-scratch")
import step1_matrix as m  # noqa: E402
import requests  # noqa: E402

PID = int(subprocess.run(["pgrep", "-f", "ftllm.cli server"], capture_output=True, text=True).stdout.split()[0])
SYSNAMES = {0: "read", 1: "write", 3: "close", 7: "poll", 8: "lseek", 9: "mmap", 10: "mprotect",
            12: "brk", 17: "pread64", 18: "pwrite64", 21: "access", 35: "nanosleep", 63: "uname",
            74: "fsync", 75: "fdatasync", 202: "futex", 232: "epoll_wait", 257: "openat",
            262: "newfstatat", 281: "epoll_pwait", 288: "accept4", 334: "rseq", 435: "clone3"}


def read_threads(pid):
    out = {}
    try:
        tids = os.listdir(f"/proc/{pid}/task")
    except Exception:
        return out
    for tid in tids:
        t = f"/proc/{pid}/task/{tid}"
        try:
            comm = open(f"{t}/comm").read().strip()
            wchan = open(f"{t}/wchan").read().strip()
            sc = open(f"{t}/syscall").read().split()
            st = open(f"{t}/stat").read().rsplit(") ", 1)[1].split()
            nr = sc[0] if sc else "?"
            out[tid] = (comm, wchan, nr, int(st[11]) + int(st[12]))
        except Exception:
            pass
    return out


state = {"stop": False}
samples = []          # (ts, tid, comm, key)
loglines = []


def sampler():
    base = read_threads(PID)
    while not state["stop"]:
        ts = time.time()
        cur = read_threads(PID)
        for tid, (comm, wchan, nr, tk) in cur.items():
            b = base.get(tid)
            if b and tk == b[3] and nr == b[2] and wchan == b[1]:
                continue                      # 无变化不记
            key = "userspace" if nr == "running" else f"sys:{SYSNAMES.get(nr, nr)}"
            if wchan and wchan not in ("0", ""):
                key += f"@{wchan[:26]}"
            samples.append((ts, tid, comm, key))
        base = cur
        time.sleep(IV)


def logwatch():
    f = open(LOG, errors="ignore")
    f.seek(0, 2)
    while not state["stop"]:
        line = f.readline()
        if not line:
            time.sleep(0.01)
            continue
        if "committed:" in line or "gc:" in line or "write skipped" in line:
            loglines.append((time.time(), line.strip()))
    f.close()


threading.Thread(target=sampler, daemon=True).start()
threading.Thread(target=logwatch, daemon=True).start()
time.sleep(DELAY)

m.BASE = "http://127.0.0.1:8080"
m.MODEL = "Qwen3.8-27B"
m.H = {"Authorization": f"Bearer {m.read_key()}", "Content-Type": "application/json"}
tk = m.get_tokenizer()
prompt = m.build_prompt(tk, 8192, "thrprobe-%d" % int(time.time() % 100000))
body = {"model": m.MODEL, "messages": [{"role": "user", "content": prompt}],
        "max_tokens": 8, "temperature": 0, "stream": True}
sess = requests.Session()
t0 = time.time()
r = sess.post(f"{m.BASE}/v1/chat/completions", headers=m.H, json=body, stream=True, timeout=900)
first = None
for line in r.iter_lines():
    if not line or not line.startswith(b"data: "):
        continue
    p = line[6:].strip()
    if p == b"[DONE]":
        break
    try:
        j = json.loads(p)
    except Exception:
        continue
    if (j.get("choices") or [{}])[0].get("delta", {}).get("content"):
        if first is None:
            first = time.time()
t_end = time.time()
print(f"REQ t0={t0:.3f} ttft={(first or t_end) - t0:.2f}s end={t_end:.3f}", flush=True)

time.sleep(max(0.0, DUR - (time.time() - t0)))
state["stop"] = True
time.sleep(0.2)

print("== 日志线（相对请求结束） ==", flush=True)
t_commit = None
for ts, line in loglines:
    print(f"  +{ts - t_end:6.2f}s  {line[:100]}", flush=True)
    if "committed:" in line and t_commit is None:
        t_commit = ts

# 导出窗口 = [t_end, committed(+2s缓冲)]
w1 = t_end - 0.5
w2 = (t_commit + 2.0) if t_commit else (t_end + 12.0)

win = collections.defaultdict(collections.Counter)
for ts, tid, comm, key in samples:
    if w1 <= ts <= w2:
        win[(tid, comm)]["n"] += 1
        win[(tid, comm)][key] += 1

print(f"== 导出窗口 [{w1 - t0:.1f}s, {w2 - t0:.1f}s] 各线程分布（按样本数，忽略纯 futex） ==", flush=True)
rows = []
for (tid, comm), c in win.items():
    n = c["n"]
    nonf = n - c.get("sys:202@futex_wait_queue", 0) - c.get("sys:futex", 0)
    if nonf < 4:
        continue
    rows.append((nonf, n, tid, comm, c))
rows.sort(key=lambda r: -r[0])
for nonf, n, tid, comm, c in rows[:14]:
    top = [f"{k}={v}" for k, v in c.most_common(9) if k != "n"]
    print(f"  tid={tid} comm={comm:14s} nonfutex={nonf:5d}/{n:5d} | " + " ".join(top), flush=True)
if not rows:
    print("  (窗口内无活跃线程 — 采样窗口/时序需调整)", flush=True)
print(f"pid={PID} total_samples={len(samples)}", flush=True)
