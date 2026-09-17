#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""fix_scan_launch.py — 生成 scan_launch_chunk.py：窗口用生产本体代码（venv site-packages）。"""
import py_compile, sys

src = "/home/ai-agent/builds/upgrade-test/scripts/scan_launch.py"
dst = "/home/ai-agent/builds/upgrade-test/scripts/scan_launch_chunk.py"
s = open(src, encoding="utf-8").read()
old = "os.environ['PYTHONPATH'] = str(W / 'overlay-fix')"
new = ("os.environ['PYTHONPATH'] = "
       "'/home/ai-agent/builds/fastllm-video-venv/lib/python3.13/site-packages'")
if old not in s:
    print("OLD_NOT_FOUND")
    sys.exit(2)
if "CHUNK-WINDOW variant" not in s:
    s = s.replace("# SCAN launcher:", "# SCAN launcher CHUNK-WINDOW variant (2026-09-17):", 1)
s = s.replace(old, new, 1)
open(dst, "w", encoding="utf-8").write(s)
py_compile.compile(dst, doraise=True)
print("OK", dst)
