#!/usr/bin/env python3
"""exp_probe.py — 「导出批量发布」修复的候选栈 A/B 探针。

对指定 base 顺序发 3 发：
  1) 全新 8K（tag-8k-a）→ 新数据写路径（全写）
  2) 全新 8K（tag-8k-b）→ 与 1) 同主体不同头 tag → 去重命中为主
  3) 全新 32K（tag-32k）  → 混合（前 8K 去重 + 后 24K 新写）
度量：每发「回答结束 t_end → [Prefix SSD] committed 行出现」的滞后（= 导出耗时，
      用户可见影响：这段时间内重复问同一题走冷路径），并抓 export:/gc: 打印。

用法:
  exp_probe.py --base http://127.0.0.1:8081 --cache <ssd_dir> --log <engine.log> \
               --out /tmp/expwindow/A --tag A
"""
import argparse, json, os, re, sqlite3, sys, threading, time

sys.path.insert(0, "/home/ai-agent/bench-scratch")
import step1_matrix as m  # noqa: E402
import requests  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--base", required=True)
ap.add_argument("--cache", required=True)
ap.add_argument("--log", required=True)
ap.add_argument("--out", required=True)
ap.add_argument("--tag", default="A")
A = ap.parse_args()

m.BASE = A.base
m.MODEL = "Qwen3.8-27B"
m.H = {"Authorization": f"Bearer {m.read_key()}", "Content-Type": "application/json"}
DB = os.path.join(A.cache, "v2/index.sqlite3")
os.makedirs(A.out, exist_ok=True)
SUMMARY = os.path.join(A.out, "SUMMARY.txt")
sess = requests.Session()
tk = m.get_tokenizer()

events = []          # (ts, line)
stop = threading.Event()


def watcher():
    try:
        fh = open(A.log, "r", errors="replace")
        fh.seek(0, os.SEEK_END)
        while not stop.is_set():
            line = fh.readline()
            if not line:
                time.sleep(0.05)
                continue
            if "[Prefix SSD]" in line:
                events.append((time.time(), line.rstrip()))
    except Exception as e:
        events.append((time.time(), f"WATCHER_ERR {type(e).__name__}: {e}"))


threading.Thread(target=watcher, daemon=True).start()


def objects():
    try:
        c = sqlite3.connect(f"file:{DB}?mode=ro", uri=True, timeout=1.0)
        c.execute("PRAGMA query_only=1")
        n, b = c.execute("SELECT COUNT(*), COALESCE(SUM(bytes),0) FROM objects").fetchone()
        c.close()
        return n, b
    except Exception:
        return -1, -1


def send(label, length, tag):
    prompt = m.build_prompt(tk, length, tag)
    body = {"model": m.MODEL, "messages": [{"role": "user", "content": prompt}],
            "max_tokens": 16, "temperature": 0, "stream": True}
    t0 = time.time()
    r = sess.post(f"{m.BASE}/v1/chat/completions", headers=m.H, json=body, stream=True, timeout=1200)
    if r.status_code != 200:
        print(f"[{label}] HTTP {r.status_code} {r.text[:200]!r}", flush=True)
        return None
    first, txt = None, ""
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
        c = (j.get("choices") or [{}])[0].get("delta", {}).get("content")
        if c:
            if first is None:
                first = time.time()
            txt += c
    t1 = time.time()
    print(f"[{label}] len={length} ttft={(first or t1) - t0:.2f}s end={t1:.3f} out={txt[:24]!r}", flush=True)
    return t1


def wait_commits(count, deadline):
    """等 count 条 committed 行出现，返回 [(ts, tokens)]"""
    got = []
    while time.time() < deadline:
        got = [(ts, int(mm.group(1))) for ts, ln in events
               for mm in [re.search(r"committed[:\s]+tokens[=\s]+(\d+)", ln)] if mm]
        if len(got) >= count:
            return got
        time.sleep(0.05)
    return got


def run_round(label, length, tag, ncommit):
    n0, b0 = objects()
    t_end = send(label, length, tag)
    if t_end is None:
        return
    deadline = time.time() + 180
    commits = wait_commits(len(seen_commits) + ncommit, deadline)
    new = commits[len(seen_commits):]
    seen_commits.extend(new)
    n1, b1 = objects()
    lag = (new[-1][0] - t_end) if new else float("nan")
    with open(SUMMARY, "a") as fh:
        fh.write(f"[{label}] len={length} end={t_end:.3f} commits={len(new)}/{ncommit} "
                 f"lag_last={lag:.2f}s lag_all={[round(c[0]-t_end,2) for c in new]} "
                 f"objects {n0}->{n1} bytes {b0}->{b1}\n")
    print(f"[{label}] LAG_LAST={lag:.2f}s commits={[round(c[0]-t_end,2) for c in new]} "
          f"objects {n0}->{n1} bytes_delta={b1-b0}", flush=True)


seen_commits = []
print(f"=== EXP_PROBE {A.tag} base={A.base} cache={A.cache} ===", flush=True)
n0, b0 = objects()
print(f"objects_start n={n0} bytes={b0}", flush=True)
run_round("8k-a", 8192, f"{A.tag}-8k-a", 1)
time.sleep(4)
run_round("8k-b", 8192, f"{A.tag}-8k-b", 1)
time.sleep(4)
run_round("32k", 32768, f"{A.tag}-32k", 4)
time.sleep(2)
with open(SUMMARY, "a") as fh:
    fh.write(f"=== export/gc 打印行（{A.tag}）===\n")
    for ts, ln in events:
        fh.write(f"{time.strftime('%H:%M:%S', time.localtime(ts))} {ln}\n")
    fh.write(f"EXP_PROBE_DONE {A.tag} {time.strftime('%F %T')}\n")
print("== export/gc 打印行 ==", flush=True)
for ts, ln in events:
    print(f"  {time.strftime('%H:%M:%S', time.localtime(ts))} {ln}", flush=True)
print(f"EXP_PROBE_DONE {A.tag} {time.strftime('%F %T')}", flush=True)
