#!/usr/bin/env python3
"""暖机 / 首请求恢复 进度查询。

用法：
  warmup_status.py            # 人类可读
  warmup_status.py --json     # 机器可读（合并三源）
  warmup_status.py --watch 3  # 每 3 秒刷新

数据源：
  - systemd 单元状态（引擎进程）
  - /home/ai-agent/ops/warmup_state.json        自动暖机执行状态（warmup_on_start.sh 写入）
  - <store>/v2/recover-progress.json            引擎内全量恢复进度（惰性化补丁上线后可用）
"""
import argparse, json, os, subprocess, sys, time

UNIT = "fastllm-qwen38-tp4"
OPS = "/home/ai-agent/ops"
STORE = "/var/cache/lmcache/prefix_ssd_prod"
PROG = os.path.join(STORE, "v2", "recover-progress.json")
STATE = os.path.join(OPS, "warmup_state.json")


def sh(cmd, default=""):
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=10).stdout.strip()
    except Exception:
        return default


def jload(p):
    try:
        return json.load(open(p))
    except Exception:
        return None


def collect():
    out = {}
    out["engine"] = {
        "active": sh("systemctl show -p ActiveState --value " + UNIT),
        "sub": sh("systemctl show -p SubState --value " + UNIT),
        "main_pid": sh("systemctl show -p MainPID --value " + UNIT),
        "active_since": sh("systemctl show -p ActiveEnterTimestamp --value " + UNIT),
        "nrestarts": sh("systemctl show -p NRestarts --value " + UNIT),
    }
    out["warmup"] = jload(STATE)
    out["recover_progress"] = jload(PROG)
    try:
        out["store_bytes"] = int(sh("du -sb " + STORE + " 2>/dev/null").split()[0])
    except Exception:
        out["store_bytes"] = None
    return out


def fmt_bytes(n):
    try:
        n = float(n)
    except Exception:
        return "n/a"
    for u in ("B", "KiB", "MiB", "GiB", "TiB"):
        if abs(n) < 1024 or u == "TiB":
            return ("%dB" % n) if u == "B" else ("%.2f%s" % (n, u))
        n /= 1024.0


def ts(v):
    try:
        return time.strftime("%F %T", time.localtime(int(v)))
    except Exception:
        return str(v)


def pretty(d):
    e, w, p = d["engine"], d.get("warmup") or {}, d.get("recover_progress")
    print("== 引擎 ==")
    print("  %s/%s  pid=%s  since=%s  restarts=%s" % (e["active"], e["sub"], e["main_pid"], e["active_since"], e["nrestarts"]))
    print("== 存储 ==")
    print("  %s  size=%s" % (STORE, fmt_bytes(d.get("store_bytes"))))
    print("== 自动暖机（warmup_on_start） ==")
    if not w:
        print("  (尚无暖机记录 —— 下次引擎启动后写入)")
    else:
        st = w.get("state", "?")
        line = "  state=%s" % st
        if w.get("started"):
            line += "  started=%s" % ts(w["started"])
        if w.get("ready_s"):
            line += "  ready=%ss" % w["ready_s"]
        line += "  engine_pid=%s" % w.get("engine_pid", "?")
        if st == "warming" and w.get("started"):
            el = int(time.time()) - int(w["started"])
            line += "  elapsed=%ss" % el
            try:
                exp = float(w.get("expected_s") or 0)
                if exp > 0:
                    line += "  eta≈%ss（按存储/295MB/s 预计总 ~%ss）" % (max(0, int(exp - el)), int(exp))
            except Exception:
                pass
        elif w.get("finished"):
            line += "  warmup_elapsed=%ss  finished=%s" % (w.get("elapsed_s", "?"), ts(w["finished"]))
        if w.get("rc") not in (None, "", "0"):
            line += "  rc=%s" % w["rc"]
        if w.get("note"):
            line += "  note=%s" % w["note"]
        print(line)
    print("== 引擎内全量恢复进度 ==")
    if not p:
        print("  (无进度文件：未做全量恢复（惰性化后为常态）或补丁未上线)")
    else:
        phase = p.get("phase", "?")
        extra = ""
        ct = p.get("commits_total")
        cd = p.get("commits_done")
        if ct:
            extra += "  commits=%s/%s" % (cd, ct)
        ob = p.get("objects_checked")
        if ob:
            extra += "  objects_checked=%s" % ob
        started = p.get("started_ns")
        if started:
            extra += "  elapsed=%.1fs" % (time.time() - float(started) / 1e9)
        print("  phase=%s%s" % (phase, extra))
        if p.get("detail"):
            print("  detail=%s" % p["detail"])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--watch", type=float, default=0)
    a = ap.parse_args()
    while True:
        d = collect()
        if a.json:
            print(json.dumps(d, ensure_ascii=False, indent=1))
        else:
            if a.watch > 0:
                sys.stdout.write("\033[2J\033[H")
            print("[%s] 暖机/恢复状态" % time.strftime("%F %T"))
            pretty(d)
        if a.watch <= 0:
            break
        time.sleep(a.watch)


if __name__ == "__main__":
    main()
