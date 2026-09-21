#!/usr/bin/env python3
"""systemd 单元补丁：挂载依赖 + ExecStartPost 自动暖机（幂等，锚点不匹配则中止）。"""
import shutil, sys

F = "/etc/systemd/system/fastllm-qwen38-tp4.service"
if "ExecStartPost" in open(F, encoding="utf-8").read():
    print("already patched"); sys.exit(0)

s = open(F, encoding="utf-8").read()
A1 = "After=network-online.target nvidia-persistenced.service\n"
A1N = A1 + "Wants=var-cache-lmcache.mount\nAfter=var-cache-lmcache.mount\n"
A2 = "ExecStart=/home/ai-agent/builds/fastllm-video-venv/bin/python /home/ai-agent/fastllm-video-repro/fastllm_prod_launch.py\n"
A2N = A2 + "ExecStartPost=/home/ai-agent/ops/warmup_on_start.sh\n"
if A1 not in s or A2 not in s:
    sys.exit("anchor not found — abort")
shutil.copy2(F, F + ".bak-pre-warmup-20260921")
s = s.replace(A1, A1N).replace(A2, A2N)
open(F, "w", encoding="utf-8").write(s)
print("unit patched OK; backup:", F + ".bak-pre-warmup-20260921")
