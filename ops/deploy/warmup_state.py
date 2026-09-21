#!/usr/bin/env python3
"""Merge k=v pairs into /home/ai-agent/ops/warmup_state.json (atomic write)."""
import json, os, sys, time

P = "/home/ai-agent/ops/warmup_state.json"
d = {}
if os.path.exists(P):
    try:
        d = json.load(open(P))
    except Exception:
        d = {}
for arg in sys.argv[1:]:
    if "=" in arg:
        k, _, v = arg.partition("=")
        d[k] = v
d["updated"] = int(time.time())
tmp = P + ".tmp"
with open(tmp, "w") as f:
    json.dump(d, f, ensure_ascii=False, indent=1)
    f.flush()
    os.fsync(f.fileno())
os.replace(tmp, P)
