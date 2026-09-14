# -*- coding: utf-8 -*-
"""AB5 grand comparison: A_pre / B / C / A_post."""
import json, re
from pathlib import Path
import sys
sys.path.insert(0, ".")
from ab5_parse import parse

CFG = {
    "A_pre (r1, 旧进程)": ("ab5_prod_A_pre.seg", "ab5_A_pre.json"),
    "B (r2默认, chunk256)": ("stack-b.log", "ab5_B.json"),
    "C (r2+16页, chunk512)": ("stack-c.log", "ab5_C.json"),
    "A_post (r1, 新进程)": ("ab5_prod_A_post.seg", "ab5_A_post.json"),
}

data = {}
for name, (logf, jsonf) in CFG.items():
    r = parse(logf)
    j = json.load(open(jsonf, encoding="utf-8"))
    jm = {c["name"]: c for c in j["cases"]}
    data[name] = (r, jm, j.get("mt", {}))

print("=" * 100)
print("C32 冷预填 ×3 (31441 tok): 逐次 ttft / 逐块求和 / 前16块均速 / 中段均速")
print("=" * 100)
for name, (r, jm, mt) in data.items():
    blocks = [b for b in r["blocks"] if b["total"] == 31441]
    tt = [jm[f"c32_r{i}"]["ttft"] for i in (1, 2, 3)]
    print(f"\n{name}")
    print(f"  ttft : {tt}  mean={sum(tt)/3:.3f}")
    for i, b in enumerate(blocks, 1):
        print(f"  rep{i}: sum_s={b['sum_s']:7.3f} lines={b['n']} chunk={b['chunk_sizes']} "
              f"first16={b['first16_mean']} mid={b['mid_mean']} last8={b['last8_mean']} "
              f"overhead={tt[i-1]-b['sum_s']:.3f}")

print()
print("=" * 100)
print("其他预填块")
print("=" * 100)
for name, (r, jm, mt) in data.items():
    line = [f"{name}:"]
    for b in r["blocks"]:
        if b["total"] == 31441: continue
        tag = {1984: "w2k", 19643: "mt_q1", 8076: "tail40"}.get(b["total"], f"q2rem")
        line.append(f"{tag}({b['total']}): sum={b['sum_s']:.3f} first16={b['first16_mean']}")
    print("  " + " | ".join(line))

print()
print("=" * 100)
print("多轮恢复 (mt)")
print("=" * 100)
for name, (r, jm, mt) in data.items():
    seeds = r["seeds"]; hits = r["hits"]
    q1_seed = [s for s in seeds if s[0] == 19643]
    q2_seed = seeds[seeds.index(q1_seed[0]) + 1] if q1_seed else None
    rest = hits[-1] if hits else None
    q2 = mt.get("q2", {})
    recompute = (q2_seed[0] - rest) if (q2_seed and rest) else None
    print(f"{name}")
    print(f"  q1: ttft={mt.get('q1',{}).get('ttft')} ctok={mt.get('q1',{}).get('ctok')} md5={mt.get('q1',{}).get('md5')}")
    print(f"  q2: restore={rest} full={q2_seed[0] if q2_seed else '?'} recompute={recompute} "
          f"ttft={q2.get('ttft')} total={q2.get('total')} ctok={q2.get('ctok')} md5={q2.get('md5')}")

print()
print("=" * 100)
print("解码 (引擎 [Decode] 行): d200 9样本 / c32 3样本 / tail40")
print("=" * 100)
for name, (r, jm, mt) in data.items():
    big = [d for d in r["decs"] if d > 150]
    d200, c32, tail = big[:9], big[9:12], big[-1]
    print(f"{name}: d200 mean={sum(d200)/len(d200):.2f} ({d200}) | c32={c32} mean={sum(c32)/len(c32):.2f} | tail40={tail}")

print()
print("=" * 100)
print("客户侧小请求")
print("=" * 100)
for name, (r, jm, mt) in data.items():
    w = jm["w2k"]; t = jm["tail40"]
    d = [jm[k]["total"] for k in ("d200_exact", "d200_r2", "d200_r3")]
    print(f"{name}: w2k ttft={w['ttft']} | d200 totals={d} | tail40 ttft={t['ttft']} total={t['total']}")
