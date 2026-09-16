#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""pooltrim_check.py — 主修验证：请求结束后 device0 是否回落到基线。

流程：基线采样 → 5 类请求（小请求 / 40K 冷预填 / 同会话增量 / 图片 / 64K 冷预填），
每请求完成后 +3s 采样 device0，并统计日志窗口内 "idle big-buffer trim" 行；
另在请求进行中每 5s 采样（记录峰值）。
验收（供人工复核）：每请求后 dev0 ≈ 基线（<= 基线+400MB），trim 行 >0，请求全 200。
"""
import base64
import json
import struct
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import zlib
from pathlib import Path

BASE = "http://127.0.0.1:8080"
MODEL = "Qwen3.8-27B-W8A16"
R = Path("/home/ai-agent/fastllm-video-repro")
LOG = R / "results/server-prod.service.log"
OUTDIR = R / "results"
KEY = ""
for _line in open("/home/ai-agent/qwen38-0.2x.env", encoding="utf-8"):
    _line = _line.strip()
    if _line.startswith("VLLM_API_KEY="):
        KEY = _line.split("=", 1)[1].strip().strip('"').strip("'")
        break
if not KEY:
    sys.exit("FATAL: VLLM_API_KEY not found")

PARA = ("The old stone bridge arched over the river, its shadow trembling on the water. "
        "Lanterns swayed along the alley, and somewhere a bamboo flute practiced the same "
        "gentle phrase, over and over, until the night learned it by heart. ")
try:
    from tokenizers import Tokenizer
    TOK = Tokenizer.from_file(
        "/home/ai-agent/fastllm-video-repro/models/nerkyor/Qwen3.8-27B-EfficientThink-FP8-lm/tokenizer.json")
except Exception:  # noqa: BLE001
    TOK = None


def filler(n, tag):
    if TOK is not None:
        ids = TOK.encode(tag + " " + PARA, add_special_tokens=False).ids
        buf = []
        while len(buf) < n:
            buf.extend(ids)
        return TOK.decode(buf[:n])
    return tag + " " + "x" * (n * 4)


def png_solid(w, h, rgb):
    raw = b"".join(b"\x00" + bytes(rgb) * w for _ in range(h))

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


def gpu_used():
    out = subprocess.check_output(
        ["nvidia-smi", "--query-gpu=index,memory.used",
         "--format=csv,noheader,nounits"]).decode()
    return [int(l.split(",")[1]) for l in out.strip().splitlines()]


def log_size():
    return LOG.stat().st_size if LOG.exists() else 0


def log_window(off):
    if not LOG.exists():
        return ""
    with open(LOG, "rb") as fh:
        fh.seek(off)
        return fh.read().decode("utf-8", "replace")


def chat(messages, max_tokens=64, timeout=1800):
    payload = {"model": MODEL, "messages": messages, "max_tokens": max_tokens,
               "temperature": 0.0, "reasoning_effort": "low"}
    req = urllib.request.Request(
        BASE + "/v1/chat/completions",
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        headers={"Content-Type": "application/json",
                 "Authorization": "Bearer " + KEY})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = json.loads(resp.read().decode("utf-8"))
        content = body["choices"][0]["message"].get("content") or ""
        return {"ok": True, "http": 200, "elapsed": time.time() - t0,
                "out_tokens": (body.get("usage") or {}).get("completion_tokens"),
                "content": content[:40]}
    except urllib.error.HTTPError as exc:
        return {"ok": False, "http": exc.code, "elapsed": time.time() - t0,
                "error": exc.read()[:150].decode("utf-8", "replace")}
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "http": -1, "elapsed": time.time() - t0,
                "error": "%s %s" % (type(exc).__name__, str(exc)[:150])}


def run(name, messages, results, baseline, tag):
    stop = threading.Event()
    peak = [0]

    def sampler():
        while not stop.is_set():
            try:
                peak[0] = max(peak[0], gpu_used()[0])
            except Exception:  # noqa: BLE001
                pass
            stop.wait(5)

    th = threading.Thread(target=sampler, daemon=True)
    th.start()
    off = log_size()
    r = chat(messages)
    stop.set()
    th.join(timeout=8)
    time.sleep(3)
    after = gpu_used()[0]
    win = log_window(off)
    trims = [l for l in win.splitlines() if "idle big-buffer trim" in l]
    row = {"name": name, "ok": r.get("ok"), "http": r.get("http"),
           "elapsed": round(r.get("elapsed", 0), 1),
           "out_tokens": r.get("out_tokens"), "error": r.get("error"),
           "dev0_peak": peak[0], "dev0_after": after,
           "after_minus_baseline": after - baseline, "trim_lines": len(trims),
           "trim_sample": trims[-1][:120] if trims else ""}
    results.append(row)
    print("[check] %-14s http=%s %6.1fs peak=%5d after=%5d (base%+d MB) trim=%d  %s"
          % (name, row["http"], row["elapsed"], row["dev0_peak"],
             row["dev0_after"], row["after_minus_baseline"], row["trim_lines"],
             row["trim_sample"]), flush=True)
    return row


def main():
    ts = time.strftime("%Y%m%d-%H%M%S")
    results = []
    baseline = gpu_used()[0]
    print("baseline dev0 used = %d MB" % baseline, flush=True)
    tag = "PT-%s" % ts

    run("small", [{"role": "user", "content": "Reply with OK."}], results,
        baseline, tag)

    p40 = filler(40960, tag + "-40k")
    run("cold40k", [{"role": "user", "content": p40 + "\n\nReply with OK."}],
        results, baseline, tag)

    msgs = [{"role": "user", "content": p40 + "\n\nReply with OK."},
            {"role": "user", "content": "[tool result] " + filler(8192, tag + "-inc")}]
    run("incr8k", list(msgs), results, baseline, tag)

    png = base64.b64encode(png_solid(1280, 720, (30, 30, 30))).decode()
    img = {"role": "user", "content": [
        {"type": "text", "text": "这张图是什么颜色？只回复颜色名。"},
        {"type": "image_url",
         "image_url": {"url": "data:image/png;base64," + png}}]}
    run("image", [img], results, baseline, tag)

    p64 = filler(65536, tag + "-64k")
    run("cold64k", [{"role": "user", "content": p64 + "\n\nReply with OK."}],
        results, baseline, tag)

    final = gpu_used()[0]
    out_json = OUTDIR / ("pooltrim-check-%s.json" % ts)
    out_json.write_text(json.dumps(
        {"ts": ts, "baseline_dev0": baseline, "final_dev0": final,
         "requests": results}, ensure_ascii=False, indent=2), encoding="utf-8")
    print("\n=== SUMMARY ===")
    worst = 0
    for row in results:
        worst = max(worst, row["after_minus_baseline"])
        print("%-14s http=%s %6.1fs after=%5d (base%+d) peak=%5d trim=%d"
              % (row["name"], row["http"], row["elapsed"], row["dev0_after"],
                 row["after_minus_baseline"], row["dev0_peak"], row["trim_lines"]))
    print("final_dev0=%d MB (baseline %d), worst_after_delta=%+d MB"
          % (final, baseline, worst))
    print("json=%s" % out_json)


if __name__ == "__main__":
    main()
