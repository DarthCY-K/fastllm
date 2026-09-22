#!/usr/bin/env python3
"""gcfix_probe.py — 候选(8081)上前缀缓存「暖恢复门闩」修复验证。

在同一窗口内对两套 .so（旧 r12 / gcfix）跑同一协议，采集:
  1) 暖请求 ttft（门闩可见性）
  2) .lease / .metadata 排他锁的连续占据时长（机制可见性）
协议与 prod 取证 stall_probe4.py 同形:
  [fill]  N 轮冷 8K（单流，唯一 tag）        → 把小配额 SSD 缓存填到压力区
  [trial] 2 连冷轮（2x32K，每轮唯一 tag） → sleep 3 → 5 波暖请求（用第 2 轮 prompt，2 并发）
  [smoke] 冷 8K + 4 波暖 8K（--smoke 1）     → 验证命中仍工作（重启后也用）
采样（0.1s，全程只读）: 两把锁的 SH-NB/EX-NB + intents 计数 + dirty + md127 扇区 + 日志大小
用法: gcfix_probe.py --cache DIR --log FILE [--base http://127.0.0.1:8081] [--fill 6]
     [--trials 1] [--smoke 0] [--out /tmp/gcfixprobe-x] [--tag old]
"""
import argparse, fcntl, json, os, random, sqlite3, string, sys, threading, time

sys.path.insert(0, "/home/ai-agent/bench-scratch")
import step1_matrix as m  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--base", default="http://127.0.0.1:8081")
ap.add_argument("--cache", required=True)
ap.add_argument("--log", required=True)
ap.add_argument("--out", default="/tmp/gcfixprobe")
ap.add_argument("--tag", default="probe")
ap.add_argument("--fill", type=int, default=6)
ap.add_argument("--fill-len", type=int, default=8192)
ap.add_argument("--len", type=int, default=32768)
ap.add_argument("--conc", type=int, default=2)
ap.add_argument("--waves", type=int, default=5)
ap.add_argument("--wave-gap", type=float, default=4.0)
ap.add_argument("--trials", type=int, default=1)
ap.add_argument("--smoke", type=int, default=0)
ap.add_argument("--model", default="")
ap.add_argument("--dev", default="nvme2n1")
A = ap.parse_args()

OUT = A.out
os.makedirs(OUT, exist_ok=True)
m.BASE = A.base
DB = f"{A.cache}/v2/index.sqlite3"
META = os.path.join(A.cache, ".metadata")
LEASE = os.path.join(A.cache, ".lease")
PROBE = open(f"{OUT}/probe.tsv", "w", buffering=1)
WAVES = open(f"{OUT}/waves.jsonl", "w", buffering=1)

m.H = {"Authorization": f"Bearer {m.read_key()}", "Content-Type": "application/json"}
sess = m.requests.Session()


def discover_model():
    """候选栈 served 模型名以 /v1/models 为准（--model_name 可能与生产不同名）。"""
    ids = []
    try:
        r = sess.get(f"{m.BASE}/v1/models", headers=m.H, timeout=10)
        ids = [x.get("id") for x in (r.json().get("data") or []) if x.get("id")]
    except Exception as e:
        print(f"# /v1/models 查询失败: {type(e).__name__}: {e}", flush=True)
    if A.model:
        pick = A.model
    elif "Qwen3.8-27B" in ids:
        pick = "Qwen3.8-27B"
    elif len(ids) == 1:
        pick = ids[0]
    else:
        pick = m.MODEL
    print(f"# served_ids={ids} -> using model={pick}", flush=True)
    return pick


m.MODEL = discover_model()
print(f"# gcfix_probe tag={A.tag} base={A.base} cache={A.cache} fill={A.fill} trials={A.trials} model={m.MODEL}", flush=True)
tk = m.get_tokenizer()

STOP = {"v": False}
_db = {"conn": None}


def flock_probe(path):
    """SH-NB 失败 => 有 EX 持有者；EX-NB 成功 => 完全空闲。"""
    fd = os.open(path, os.O_RDONLY)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
            sh = 1
            fcntl.flock(fd, fcntl.LOCK_UN)
        except OSError:
            sh = 0
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            ex = 1
            fcntl.flock(fd, fcntl.LOCK_UN)
        except OSError:
            ex = 0
    finally:
        os.close(fd)
    return sh, ex


def intents_count():
    try:
        if _db["conn"] is None:
            c = sqlite3.connect(f"file:{DB}?mode=ro", uri=True, timeout=0.4)
            c.execute("PRAGMA query_only=1")
            _db["conn"] = c
        _db["conn"].execute("BEGIN")
        n = _db["conn"].execute("SELECT COUNT(*) FROM intents").fetchone()[0]
        _db["conn"].execute("COMMIT")
        return n
    except Exception:
        _db["conn"] = None
        return -9


def dirty_kb():
    try:
        for line in open("/proc/meminfo"):
            if line.startswith("Dirty:"):
                return int(line.split()[1])
    except Exception:
        pass
    return -1


def md_sectors():
    try:
        for line in open("/proc/diskstats"):
            p = line.split()
            if len(p) > 9 and p[2] == A.dev:
                return int(p[5]) * 512, int(p[9]) * 512
    except Exception:
        pass
    return 0, 0


def log_size():
    try:
        return os.path.getsize(A.log)
    except Exception:
        return -1


def sampler():
    prev = md_sectors()
    while not STOP["v"]:
        t = time.time()
        try:
            lsh, lex = flock_probe(LEASE)
            msh, mex = flock_probe(META)
            cur = md_sectors()
            PROBE.write(f"{t:.3f}\t{lsh}\t{lex}\t{msh}\t{mex}\t{intents_count()}\t{dirty_kb()}\t"
                        f"{cur[0]-prev[0]}\t{cur[1]-prev[1]}\t{log_size()}\n")
            prev = cur
        except Exception as e:
            PROBE.write(f"{t:.3f}\tERR\t{type(e).__name__}:{e}\n")
        time.sleep(0.1)


threading.Thread(target=sampler, daemon=True).start()


def T():
    return "".join(random.choices(string.ascii_lowercase + string.digits, k=6))


def emit(rec, meta):
    rec.update(meta)
    rec["ts_epoch"] = time.time()
    rec["ts_iso"] = time.strftime("%F %T")
    WAVES.write(json.dumps(rec, ensure_ascii=False) + "\n")
    print(f"  [{meta['phase']}] {rec['req']} ttft={rec.get('ttft')} cached={rec.get('cached_tokens')} "
          f"dec={rec.get('decode_tps')} {rec.get('error') or ''}", flush=True)


fail_404 = 0
for r in range(1, A.fill + 1):
    tg = f"gcf-{A.tag}-fill{r}-{T()}"
    p = m.build_prompt(tk, A.fill_len, tg)
    print(f"== fill {r}/{A.fill} (cold {A.fill_len}) ==", flush=True)
    for rec in m.wave([p], [f"fill{r}"], sess, 1):
        emit(rec, {"phase": f"fill{r}"})
        if "404" in str(rec.get("error") or ""):
            fail_404 += 1
        else:
            fail_404 = 0
    if fail_404 >= 2:
        print("FATAL: 连续 404（模型名不匹配？）→ 中止，避免烧窗口", flush=True)
        STOP["v"] = True
        sys.exit(2)
    time.sleep(1.0)

for t in range(1, A.trials + 1):
    ps = None
    for r in (1, 2):
        tg = f"gcf-{A.tag}-t{t}r{r}-{T()}"
        ps = [m.build_prompt(tk, A.len, f"{tg}-{i}") for i in range(A.conc)]
        print(f"== trial{t} cold round {r}/2 ({A.conc}x{A.len}) ==", flush=True)
        for rec in m.wave(ps, [f"t{t}-cold-r{r}-s{i}" for i in range(A.conc)], sess, A.conc):
            emit(rec, {"phase": f"t{t}_cold_r{r}", "trial": t, "round": r})
        time.sleep(1.5)
    time.sleep(3)
    for i in range(1, A.waves + 1):
        t0 = time.time()
        for rec in m.wave(ps, [f"t{t}-warm{i}-s{j}" for j in range(A.conc)], sess, A.conc):
            emit(rec, {"phase": f"t{t}_warm{i}", "trial": t, "round": i})
        wall = time.time() - t0
        WAVES.write(json.dumps({"phase": f"t{t}_warm{i}_wall", "wall": round(wall, 3),
                                "ts_epoch": time.time()}) + "\n")
        print(f"  .. warm{i} wall={wall:.2f}s", flush=True)
        if i < A.waves:
            time.sleep(A.wave_gap)

if A.smoke:
    p = m.build_prompt(tk, A.fill_len, f"gcf-{A.tag}-smoke-{T()}")
    print(f"== smoke cold {A.fill_len} ==", flush=True)
    for rec in m.wave([p], ["smoke-cold"], sess, 1):
        emit(rec, {"phase": "smoke_cold"})
    time.sleep(2)
    for i in range(1, 5):
        for rec in m.wave([p], [f"smoke-warm{i}"], sess, 1):
            emit(rec, {"phase": f"smoke_warm{i}", "round": i})
        time.sleep(2)

print("# tail 20s (writer drain)", flush=True)
time.sleep(20)
STOP["v"] = True
time.sleep(0.3)

# ---------------- 汇总 ----------------
samples = []
for line in open(f"{OUT}/probe.tsv"):
    if line.startswith("#"):
        continue
    r = line.rstrip("\n").split("\t")
    if len(r) < 10 or r[1] in ("ERR", ""):
        continue
    try:
        samples.append((float(r[0]), int(r[1]), int(r[3]), int(r[5])))
    except ValueError:
        continue


def longest_run(kind):
    best, bstart, cur, cstart = 0.0, None, 0.0, None
    for t, lsh, msh, _n in samples:
        held = (lsh == 0) if kind == "lease" else (msh == 0)
        if held:
            if cstart is None:
                cstart = t
            cur = t - cstart
            if cur > best:
                best, bstart = cur, cstart
        else:
            cstart = None
            cur = 0.0
    return best, bstart


waves = [json.loads(x) for x in open(f"{OUT}/waves.jsonl") if x.strip()]
warm = [w for w in waves if "_warm" in w.get("phase", "") and "wall" not in w["phase"]]
wall = [w for w in waves if w.get("phase", "").endswith("_wall")]
cold = [w for w in waves if "cold" in w.get("phase", "")]
cached_ok = sum(1 for w in warm if (w.get("cached_tokens") or 0) > 0)
tt = [w.get("ttft") or -1 for w in warm]
lease_hold, lease_at = longest_run("lease")
meta_hold, meta_at = longest_run("meta")
n_stall = sum(1 for x in tt if x is not None and x > 1.5)
lines = [
    f"=== gcfix_probe SUMMARY tag={A.tag} ({time.strftime('%F %T')}) ===",
    f"samples={len(samples)}  warm_reqs={len(warm)}  warm_cached_hit={cached_ok}",
    f"warm_ttft: max={max(tt) if tt else -1:.2f}s  median={sorted(tt)[len(tt)//2] if tt else -1:.2f}s  "
    f"stalls(>1.5s)={n_stall}  list={[round(x, 2) for x in tt]}",
    f"warm_wall: {[w['wall'] for w in wall]}",
    f"cold_ttft: {[ (w.get('ttft') or -1) for w in cold ]}",
    f"lease_EX_longest={lease_hold:.2f}s at t={lease_at}",
    f"meta_EX_longest={meta_hold:.2f}s at t={meta_at}",
]
try:
    gc = [l.strip() for l in open(A.log, errors="ignore") if "[Prefix SSD] gc:" in l]
    lines.append(f"gc_prints={len(gc)}")
    lines += ["  " + l for l in gc[-6:]]
except Exception as e:
    lines.append(f"gc_prints=ERR {e}")
txt = "\n".join(lines)
open(f"{OUT}/SUMMARY.txt", "w").write(txt + "\n")
print(txt, flush=True)
print(f"DONE -> {OUT}/", flush=True)
