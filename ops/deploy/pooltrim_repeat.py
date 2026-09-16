#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""pooltrim_repeat.py — 重复压力：确认残留是否平台化（不随请求数持续增长）。

5 × 图片请求（每次图像略有不同，避开嵌入缓存）+ 2 × 64K 冷预填；
每请求后打印 dev0 与 trim 行。
"""
import base64
import json
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.request
import zlib
from pathlib import Path

BASE = "http://127.0.0.1:8080"
MODEL = "Qwen3.8-27B-W8A16"
R = Path("/home/ai-agent/fastllm-video-repro")
LOG = R / "results/server-prod.service.log"
OUT = R / "results"
KEY = ""
for _l in open("/home/ai-agent/qwen38-0.2x.env", encoding="utf-8"):
    if _l.startswith("VLLM_API_KEY="):
        KEY = _l.split("=", 1)[1].strip().strip('"').strip("'")
        break
if not KEY:
    sys.exit("NO_KEY")
PARA = ("The old stone bridge arched over the river, its shadow trembling on the water. ")
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


def png(w, h, base_rgb):
    raw = b"".join(b"\x00" + bytes(base_rgb) * w for _ in range(h))

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


def gpu0():
    out = subprocess.check_output(
        ["nvidia-smi", "--query-gpu=memory.used", "--format=csv,noheader,nounits",
         "-i", "0"]).decode()
    return int(out.strip().splitlines()[0])


def log_size():
    return LOG.stat().st_size if LOG.exists() else 0


def chat(messages, max_tokens=48, timeout=1800):
    payload = {"model": MODEL, "messages": messages, "max_tokens": max_tokens,
               "temperature": 0.0, "reasoning_effort": "low"}
    req = urllib.request.Request(
        BASE + "/v1/chat/completions",
        data=json.dumps(payload, ensure_ascii=False).encode(),
        headers={"Content-Type": "application/json",
                 "Authorization": "Bearer " + KEY})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            body = json.loads(r.read())
        return {"ok": True, "elapsed": time.time() - t0,
                "usage": body.get("usage")}
    except urllib.error.HTTPError as e:
        return {"ok": False, "elapsed": time.time() - t0, "error": "HTTP %d" % e.code}
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "elapsed": time.time() - t0,
                "error": "%s" % type(e).__name__}


def main():
    ts = time.strftime("%Y%m%d-%H%M%S")
    rows = []
    base0 = gpu0()
    print("baseline dev0 = %d MB" % base0, flush=True)
    for i in range(5):
        png_b64 = base64.b64encode(png(1280, 720, (20 + i * 30, 30, 30))).decode()
        msg = {"role": "user", "content": [
            {"type": "text", "text": "这张图是什么颜色？只回复颜色名。"},
            {"type": "image_url",
             "image_url": {"url": "data:image/png;base64," + png_b64}}]}
        off = log_size()
        r = chat([msg])
        time.sleep(3)
        after = gpu0()
        with open(LOG, "rb") as fh:
            fh.seek(off)
            win = fh.read().decode("utf-8", "replace")
        trims = [l for l in win.splitlines() if "idle big-buffer trim" in l]
        rows.append(("image%d" % i, r, after, trims[-1][:100] if trims else ""))
        print("image%d ok=%s %.1fs dev0=%d (base%+d) %s"
              % (i, r.get("ok"), r.get("elapsed", 0), after, after - base0,
                 trims[-1][:90] if trims else "no-trim"), flush=True)
    for i in range(2):
        text = filler(65536, "PTR-%s-%d" % (ts, i))
        off = log_size()
        r = chat([{"role": "user", "content": text + "\n\nReply with OK."}])
        time.sleep(3)
        after = gpu0()
        with open(LOG, "rb") as fh:
            fh.seek(off)
            win = fh.read().decode("utf-8", "replace")
        trims = [l for l in win.splitlines() if "idle big-buffer trim" in l]
        rows.append(("cold64k-%d" % i, r, after, trims[-1][:100] if trims else ""))
        print("cold64k-%d ok=%s %.1fs dev0=%d (base%+d) %s"
              % (i, r.get("ok"), r.get("elapsed", 0), after, after - base0,
                 trims[-1][:90] if trims else "no-trim"), flush=True)
    out = OUT / ("pooltrim-repeat-%s.json" % ts)
    out.write_text(json.dumps(
        {"baseline_dev0": base0, "ts": ts,
         "rows": [{"name": n, "ok": r.get("ok"), "elapsed": r.get("elapsed"),
                   "dev0_after": a, "trim": t} for n, r, a, t in rows]},
        ensure_ascii=False, indent=2), encoding="utf-8")
    print("json=%s" % out)


if __name__ == "__main__":
    main()
