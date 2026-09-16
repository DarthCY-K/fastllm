#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""apply_nslog_redact.py — 给 ftllm 的启动 Namespace 日志加脱敏（幂等）。

问题：`ftllm/openai_server/server.py` 里 `logging.info(args)` 会把完整 argv 打进 stdout/日志，
其中 `--api_key` 是明文 —— 每次重启都把一个 64-hex 生产密钥写进日志（历史 47 次）。

修法：只改"打印用的对象"，不动真实 args（避免后续鉴权拿不到 key）：
    logging.info(args)  ->  logging.info(type(args)(**{**vars(args), "api_key": "[REDACTED]"}))
"""
import pathlib, py_compile, re, shutil, sys

VENV = pathlib.Path("/home/ai-agent/builds/fastllm-video-venv/lib/python3.13/site-packages/ftllm")
TARGET = 'logging.info(args)'
PATCHED = 'logging.info(type(args)(**{**vars(args), "api_key": "[REDACTED]"}))'


def main():
    hits = []
    for p in VENV.rglob("server.py"):
        try:
            s = p.read_text(encoding="utf-8")
        except Exception:
            continue
        if TARGET in s or "api_key\": \"[REDACTED]\"" in s:
            hits.append((p, s))
    if not hits:
        print("NO_TARGET_FILE"); return 2
    changed = 0
    for p, s in hits:
        if PATCHED in s:
            print("already patched:", p)
            continue
        if TARGET not in s:
            print("target line not found in", p)
            continue
        bak = p.with_suffix(".py.bak-pre-nslog-redact")
        if not bak.exists():
            shutil.copy2(p, bak)
            print("backup ->", bak)
        s2 = s.replace(TARGET, PATCHED, 1)
        p.write_text(s2, encoding="utf-8")
        py_compile.compile(str(p), doraise=True)
        changed += 1
        print("patched:", p)
    print("changed_files=%d" % changed)
    return 0


if __name__ == "__main__":
    sys.exit(main())
