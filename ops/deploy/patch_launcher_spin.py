#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ncclab launcher 补：用 NCCL_SPIN（非 FASTLLM_ 前缀，能穿过 pop）中转，弹出后再注入 FASTLLM_NCCL_RENDEZVOUS_SPIN。"""
import pathlib
p = pathlib.Path('/home/ai-agent/builds/upgrade-test/fastllm_test_launch_r13ncclab.py')
s = p.read_text(encoding='utf-8')
if 'NCCL_SPIN' in s:
    print('already patched'); raise SystemExit(0)

anchor = "for k in list(os.environ):"
cap = "_nccl_spin = os.environ.get('NCCL_SPIN')\n"
assert anchor in s
s = s.replace(anchor, cap + anchor, 1)

anchor2 = "os.environ['PYTHONPATH'] = str(W / os.environ.get('OVERLAY', 'overlay-r13-ncclab'))"
inject = anchor2 + "\nif _nccl_spin is not None and _nccl_spin != '':\n    os.environ['FASTLLM_NCCL_RENDEZVOUS_SPIN'] = _nccl_spin"
assert anchor2 in s
s = s.replace(anchor2, inject, 1)
p.write_text(s, encoding='utf-8')
print('patched')
for i, line in enumerate(s.splitlines(), 1):
    if 'NCCL_SPIN' in line or 'FASTLLM_NCCL_RENDEZVOUS_SPIN' in line or 'for k in list' in line:
        print(i, repr(line))
