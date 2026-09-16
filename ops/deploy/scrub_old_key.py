#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""scrub_old_key.py — 把旧 API key 从历史日志里就地抹除（同长度替换，保持 inode；不动 env 与其备份）。

用法: scrub_old_key.py [/home/ai-agent/qwen38-0.2x.env.bak-pre-rotate-20260916] [--roots ...]
判据：只处理包含旧 key 的文件；替换为等长占位符（64 字节），使偏移/文件长度不变，
     从而不影响任何已按行引用的日志分析；全程不回显密钥。
"""
import argparse, os, pathlib, sys

PLACEHOLDER = b"[REDACTED-KEY-20260916]".ljust(64, b"*")
KEEP = {"/home/ai-agent/qwen38-0.2x.env",  # 当前 env = 新 key
        "/home/ai-agent/fastllm-video-repro/results/server-prod.service.log",  # live 追加日志：改会丢尾部数据，留给下次停服务窗口
        "/home/ai-agent/qwen38-0.2x.env.bak-pre-rotate-20260916"}  # 回滚句柄（600）


def load_old(path):
    for line in open(path, encoding="utf-8", errors="replace"):
        if line.strip().startswith("VLLM_API_KEY="):
            return line.strip().split("=", 1)[1].strip().strip('"').strip("'").encode()
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("bak", nargs="?", default="/home/ai-agent/qwen38-0.2x.env.bak-pre-rotate-20260916")
    ap.add_argument("--roots", default="/home/ai-agent,/var/log,/tmp")
    ap.add_argument("--report", default="/home/ai-agent/builds/upgrade-test/scrub-report.txt")
    a = ap.parse_args()
    key = load_old(a.bak)
    if not key:
        print("NO_OLD_KEY_IN", a.bak); return 2
    skip = {".git", "__pycache__", "node_modules"}
    rep, scrubbed, files = [], 0, 0
    for root in a.roots.split(","):
        for dp, dns, fns in os.walk(root):
            dns[:] = [d for d in dns if d not in skip]
            for fn in fns:
                p = os.path.join(dp, fn)
                if p in KEEP or os.path.islink(p):
                    continue
                try:
                    if os.path.getsize(p) > 400 * 1024 * 1024:
                        continue
                    with open(p, "r+b") as f:
                        data = f.read()
                        n = data.count(key)
                        if n:
                            f.seek(0)
                            f.write(data.replace(key, PLACEHOLDER))
                            f.truncate()
                            scrubbed += n
                            files += 1
                            rep.append("%s  occurrences=%d" % (p, n))
                except Exception:
                    continue
    open(a.report, "w", encoding="utf-8").write(
        "files_scrubbed=%d occurrences=%d\n%s\n" % (files, scrubbed, "\n".join(rep)))
    print("files_scrubbed=%d occurrences=%d report=%s" % (files, scrubbed, a.report))
    for line in rep[:20]:
        print("  " + line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
