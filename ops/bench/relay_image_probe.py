#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""relay_image_probe.py — 走客户端真实链路（subapi 中继）验证图像端到端。
密钥从 Hermes .env 的 QWEN_API_KEY 读取，绝不打印。
用法: relay_image_probe.py [out.json]
"""
import base64, json, os, sys, urllib.request, urllib.error, zlib, struct

ENV = os.path.expandvars(r"%LOCALAPPDATA%\hermes\.env")
BASE = "https://subapi.kjsygame.com/v1"
MODEL = "Qwen3.8-27B-W8A16"
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.expandvars(
    r"%LOCALAPPDATA%\hermes\cache\etfp8-ab\r5-20260916\relay-image-probe.json")

KEY = None
for line in open(ENV, encoding="utf-8", errors="replace"):
    line = line.strip()
    if line.startswith("QWEN_API_KEY="):
        KEY = line.split("=", 1)[1].strip().strip('"').strip("'")
        break
if not KEY:
    print("NO_KEY_FOUND"); sys.exit(2)


def png_solid(w, h, rgb):
    raw = b"".join(b"\x00" + bytes(rgb) * w for _ in range(h))

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


res = {"base": BASE, "cases": []}
for name, rgb, keys in [("orange", (255, 140, 0), ["orange", "橙", "橘"]),
                        ("blue", (0, 90, 255), ["blue", "蓝"])]:
    url = "data:image/png;base64," + base64.b64encode(png_solid(96, 96, rgb)).decode()
    body = {"model": MODEL, "max_tokens": 24, "temperature": 0, "stream": False,
            "messages": [{"role": "user", "content": [
                {"type": "text", "text": "What is the dominant color of this image? Answer with exactly one English color word."},
                {"type": "image_url", "image_url": {"url": url}}]}]}
    req = urllib.request.Request(BASE + "/chat/completions", data=json.dumps(body).encode(),
                                headers={"Authorization": "Bearer " + KEY,
                                         "Content-Type": "application/json"})
    e = {"expected": name, "model_requested": MODEL}
    try:
        with urllib.request.urlopen(req, timeout=180) as r:
            j = json.loads(r.read().decode("utf-8", "replace"))
        msg = (j.get("choices") or [{}])[0].get("message") or {}
        txt = ((msg.get("content") or "") + " " + (msg.get("reasoning_content") or "")).strip()
        e.update({"http": 200, "served_model": j.get("model"), "text": txt[:120],
                  "ok": any(k.lower() in txt.lower() for k in keys)})
    except urllib.error.HTTPError as ex:
        e.update({"http": ex.code, "text": ex.read().decode("utf-8", "replace")[:200], "ok": False})
    except Exception as ex:
        e.update({"http": -1, "text": repr(ex)[:200], "ok": False})
    res["cases"].append(e)
    print("%-7s http=%s ok=%s served=%s text=%r" % (name, e.get("http"), e.get("ok"),
                                                    e.get("served_model"), e.get("text", "")[:60]), flush=True)

res["ok_all"] = all(c.get("ok") for c in res["cases"])
open(OUT, "w", encoding="utf-8").write(json.dumps(res, ensure_ascii=False, indent=1))
print("RELAY_IMAGE_PROBE ok_all=%s -> %s" % (res["ok_all"], OUT))
