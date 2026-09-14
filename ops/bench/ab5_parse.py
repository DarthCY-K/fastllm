# -*- coding: utf-8 -*-
"""Parse AB5 segment logs into per-prefill block accounting."""
import re, sys, json
from pathlib import Path

LP = re.compile(r"\[Prompt\] Long Prefill \.\.\. \((\d+)/(\d+), (\d+)%\)\. Speed: ([\d.]+) tokens / s\.")
SEED = re.compile(r"long prefill cache seeded: tokens=(\d+), chunk=(\d+)")
HIT = re.compile(r"prefix cache (?:hit|restored[^:]*): tokens=(\d+)")
DEC = re.compile(r"\[Decode\][^S]*Speed: ([\d.]+) tokens / s\.")
SHORT = re.compile(r"\[Prompt\] (\d+) Tokens\. Speed: ([\d.]+) tokens / s\.")

def parse(path):
    lines = Path(path).read_text(errors="ignore").splitlines()
    blocks = []; cur = None; pending_restore = 0
    seeds = []; hits = []; decs = []; shorts = []
    for ln in lines:
        m = LP.search(ln)
        if m:
            pos, tot, pct, sp = int(m.group(1)), int(m.group(2)), int(m.group(3)), float(m.group(4))
            if cur is None or tot != cur["total"] or pos <= cur["prev"]:
                if cur: blocks.append(cur)
                cur = {"total": tot, "pts": [], "prev": 0}
                pending_restore = 0
            cur["pts"].append((pos, sp)); cur["prev"] = pos
            continue
        m = SEED.search(ln)
        if m:
            seeds.append((int(m.group(1)), int(m.group(2)))); continue
        m = HIT.search(ln)
        if m:
            pending_restore = max(pending_restore, int(m.group(1))); hits.append(int(m.group(1))); continue
        m = DEC.search(ln)
        if m:
            decs.append(float(m.group(1))); continue
        m = SHORT.search(ln)
        if m:
            shorts.append((int(m.group(1)), float(m.group(2)))); continue
    if cur: blocks.append(cur)
    for b in blocks:
        prev = b["prev0"] if "prev0" in b else 0; s = 0.0; sizes = []; sps = []
        for pos, sp in b["pts"]:
            n = pos - prev; prev = pos
            sizes.append(n); sps.append(sp); s += n / sp
        b["size_seq"] = sizes; b["speeds"] = sps; b["sum_s"] = round(s, 3)
        b["tokens_processed"] = b["total"]
        b["n"] = len(b["pts"]); b["last_chunk"] = sizes[-1] if sizes else 0
        b["chunk_sizes"] = sorted(set(sizes))
        ex = sps[:16]; mid = sps[16:-8] if len(sps) > 24 else []
        b["first16_mean"] = round(sum(ex) / len(ex), 1) if ex else None
        b["mid_mean"] = round(sum(mid) / len(mid), 1) if mid else None
        b["last8_mean"] = round(sum(sps[-8:]) / len(sps[-8:]), 1) if sps else None
    return {"blocks": blocks, "seeds": seeds, "hits": hits, "decs": decs, "shorts": shorts}

if __name__ == "__main__":
    for path in sys.argv[1:]:
        r = parse(path)
        print("=" * 20, path)
        print("seeds:", r["seeds"])
        print("hits :", r["hits"])
        print("shorts:", r["shorts"])
        print("decs :", r["decs"])
        for i, b in enumerate(r["blocks"]):
            print(f"B{i}: total={b['total']} lines={b['n']} "
                  f"chunks={b['chunk_sizes']} first={b['size_seq'][:2]} last={b['last_chunk']} "
                  f"sum_s={b['sum_s']} first16={b['first16_mean']} mid={b['mid_mean']} last8={b['last8_mean']}")
