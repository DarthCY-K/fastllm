#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""scan_key_files.py — 扫描本机（盒子）上哪些文件包含生产 API key（只输出文件名与出现次数，绝不回显密钥）。
用法: scan_key_files.py [--roots /home/ai-agent,/var/log,/tmp] [--limit-bytes 200000000]
"""
import os, sys, argparse

ENV = "/home/ai-agent/qwen38-0.2x.env"


def load_key():
    for line in open(ENV, encoding="utf-8", errors="replace"):
        line = line.strip()
        if line.startswith("VLLM_API_KEY="):
            return line.split("=", 1)[1].strip().strip('"').strip("'")
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--roots", default="/home/ai-agent,/var/log,/tmp")
    ap.add_argument("--limit-bytes", type=int, default=200 * 1024 * 1024)
    ap.add_argument("--skip-dirs", default=".git,__pycache__,node_modules,.cache")
    a = ap.parse_args()
    key = load_key()
    if not key:
        print("NO_KEY"); return 2
    kb = key.encode()
    skip = set(a.skip_dirs.split(","))
    hits = []
    scanned = 0
    for root in a.roots.split(","):
        for dp, dns, fns in os.walk(root):
            dns[:] = [d for d in dns if d not in skip]
            for fn in fns:
                p = os.path.join(dp, fn)
                try:
                    if os.path.getsize(p) > a.limit_bytes:
                        continue
                    with open(p, "rb") as f:
                        data = f.read()
                except Exception:
                    continue
                scanned += 1
                n = data.count(kb)
                if n:
                    hits.append((p, n, len(data)))
    print("scanned_files=%d  hit_files=%d" % (scanned, len(hits)))
    for p, n, sz in sorted(hits, key=lambda x: -x[1]):
        print("HIT  %-90s occurrences=%-6d size=%d" % (p, n, sz))
    return 0


if __name__ == "__main__":
    sys.exit(main())
