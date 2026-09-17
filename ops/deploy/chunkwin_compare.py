#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""chunkwin_compare.py FILE... — chunk 窗口多配置对比：
case × 配置 的 total秒/md5 + 派生 prefill tok/s 与 decode t/s + mt3 全量。"""
import json, sys

runs = [json.load(open(f, encoding="utf-8")) for f in sys.argv[1:]]
names = []
for r in runs:
    for c in r.get("cases", []):
        n = c.get("name")
        if n and n not in names:
            names.append(n)

print("== 各 case：total 秒 / md5前缀 ==")
print("%-8s" % "case" + "".join("%20s" % r.get("tag") for r in runs))
for n in names:
    row = "%-8s" % n
    for r in runs:
        c = next((x for x in r.get("cases", []) if x.get("name") == n), None)
        row += "%20s" % (("%.3fs %s" % (c["total"], c.get("md5", "")[:4])) if c and "total" in c else "-")
    print(row)

print()
print("== 派生指标（prefill tok/s = ptok/ttft；d200 decode t/s） ==")
print("%-8s" % "case" + "".join("%20s" % r.get("tag") for r in runs))
for n in names:
    row = "%-8s" % n
    for r in runs:
        c = next((x for x in r.get("cases", []) if x.get("name") == n), None)
        cell = "-"
        if c and c.get("ttft") and c.get("ptok_est"):
            if n.startswith("c"):
                cell = "%.0f t/s" % (c["ptok_est"] / c["ttft"])
            elif n.startswith("d200") and c.get("ctok") and c.get("total"):
                cell = "%.1f t/s" % (c["ctok"] / (c["total"] - c["ttft"]))
            else:
                cell = "ttft=%.3f" % c["ttft"]
        row += "%20s" % cell
    print(row)

print()
print("== mt3（多轮复原粒度探针） ==")
for r in runs:
    mt = r.get("mt3")
    if mt:
        print(r.get("tag"), json.dumps(mt, ensure_ascii=False))
