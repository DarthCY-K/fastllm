#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""Extract engine-side decode samples for blocks whose seeded/restored token count matches
a target list (AB-suite anchors). Prints every occurrence in log order.

Usage: extract_blocks.py <log> <tok1,tok2,...> [max_per_target]
"""
import re, sys

targets = set(int(x) for x in sys.argv[2].split(","))
max_per_target = int(sys.argv[3]) if len(sys.argv) > 3 else 4
log = sys.argv[1]

seed_re = re.compile(r'long prefill cache seeded: tokens=(\d+), chunk=(\d+)')
rest_re = re.compile(r'prefix cache (?:restored|hit): tokens=(\d+)')
alive_re = re.compile(r'alive = (\d+), pending = (\d+).*Speed: ([\d.]+) tokens / s')
acc_re  = re.compile(r'pos_accept_rate=\[([^\]]*)\]')
ts_re   = re.compile(r'^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)')
pf_re   = re.compile(r'MTP profile\] samples=\d+ paths=\{seed=(\d+),tp_inplace=(\d+),tp_copy=(\d+),single=(\d+)\} accept=\{spec=(\d+),full=(\d+),partial=(\d+),reject0=(\d+)\} avg_tokens=\{commit=([\d.]+),matched_draft=([\d.]+)')

cur, out, last_ts = None, [], "?"
def flush():
    if cur and cur["tokens"] in targets:
        out.append(dict(cur))
for ln, line in enumerate(open(log, encoding="utf-8", errors="ignore"), 1):
    m = ts_re.match(line)
    if m:
        last_ts = m.group(1)
    if "long prefill cache seeded" in line:
        flush(); cur = {"type": "cold", "tokens": int(seed_re.search(line).group(1)), "sp": [], "acc": None, "prof": None, "ts": last_ts}
        continue
    if "prefix cache restored" in line or "prefix cache hit" in line:
        flush(); cur = {"type": "warm", "tokens": int(rest_re.search(line).group(1)), "sp": [], "acc": None, "prof": None, "ts": last_ts}
        continue
    if cur is None:
        continue
    m = alive_re.search(line)
    if m:
        if m.group(1) == "1" and m.group(2) == "0":
            cur["sp"].append(float(m.group(3)))
        continue
    m = acc_re.search(line)
    if m:
        cur["acc"] = m.group(1)
    m = pf_re.search(line)
    if m:
        cur["prof"] = tuple(float(x) for x in m.groups())
flush()

counts, shown = {}, {}
print("targets=%s  matched blocks=%d" % (sorted(targets), len(out)))
print("%-6s %-8s %-4s %-11s %-11s %-8s %-6s %-6s %s" % ("when", "tokens", "n", "eng_max", "eng_mean", "commit", "spec", "full", "accept"))
for b in out:
    counts[b["tokens"]] = counts.get(b["tokens"], 0) + 1
    if shown.get(b["tokens"], 0) >= max_per_target:
        continue
    shown[b["tokens"]] = shown.get(b["tokens"], 0) + 1
    sp, p = b["sp"], b["prof"]
    print("%-6s %-8d %-4d %-11s %-11s %-8s %-6s %-6s %s" % (
        b["ts"][-8:], b["tokens"], len(sp),
        ("%.1f" % max(sp)) if sp else "-", ("%.1f" % (sum(sp) / len(sp))) if sp else "-",
        ("%.2f" % p[8]) if p else "-", ("%d" % p[4]) if p else "-", ("%d" % p[5]) if p else "-",
        (b["acc"] or "-")[:40]))
print("occurrences:", {k: counts[k] for k in sorted(counts)})
