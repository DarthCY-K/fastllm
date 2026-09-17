#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""apply_chunk2048.py — 生产 argv 转正：chunk 2048 + interval 16（2026-09-17 组合窗获胜配置）。
备份 = argv-prod-tp4.json.bak-pre-chunk2048-20260917；回滚见 rollback_chunk2048.py。"""
import json, os, shutil

p = "/home/ai-agent/fastllm-video-repro/results/argv-prod-tp4.json"
bak = p + ".bak-pre-chunk2048-20260917"
d = json.load(open(p, encoding="utf-8"))
argv = d["argv"]


def setflag(flag, val):
    if flag not in argv:
        raise SystemExit("NOFLAG " + flag)
    i = argv.index(flag)
    if i + 1 >= len(argv) or argv[i + 1].startswith("--"):
        raise SystemExit("NOVAL " + flag)
    old = argv[i + 1]
    argv[i + 1] = val
    return old


old1 = setflag("--chunked_prefill_size", "2048")
old2 = setflag("--prefix_cache_snapshot_interval_pages", "16")
if not os.path.exists(bak):
    shutil.copy2(p, bak)
json.dump(d, open(p, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
print("OLD chunk=%s interval=%s -> NEW 2048/16 | backup=%s" % (old1, old2, bak))
