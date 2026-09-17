#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""rollback_chunk2048.py — 还原 pre-chunk2048 生产 argv。"""
import shutil, sys

p = "/home/ai-agent/fastllm-video-repro/results/argv-prod-tp4.json"
bak = p + ".bak-pre-chunk2048-20260917"
try:
    shutil.copy2(bak, p)
    print("RESTORED", p)
except FileNotFoundError:
    print("NO_BACKUP")
    sys.exit(2)
