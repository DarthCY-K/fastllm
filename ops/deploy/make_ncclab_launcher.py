#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""由 fastllm_test_launch_r13.py 派生 ncclab 版：OVERLAY 可取 overlay-r13-ncclab / overlay-r13。"""
import pathlib, re, sys

W = pathlib.Path('/home/ai-agent/builds/upgrade-test')
src = (W / 'fastllm_test_launch_r13.py').read_text(encoding='utf-8')
print("--- 原 launcher 里的 overlay 行 ---")
for line in src.splitlines():
    if 'overlay' in line:
        print(repr(line))

new = re.sub(r"W\s*/\s*'overlay-r13'", "W / os.environ.get('OVERLAY', 'overlay-r13-ncclab')", src)
if new == src:
    new = src.replace("'overlay-r13'", "os.environ.get('OVERLAY', 'overlay-r13-ncclab')")
assert 'OVERLAY' in new, 'replacement failed'
out = W / 'fastllm_test_launch_r13ncclab.py'
out.write_text(new, encoding='utf-8')
print("--- 新版 overlay 行 ---")
for line in new.splitlines():
    if 'OVERLAY' in line or 'overlay' in line:
        print(repr(line))
print("written:", out)
