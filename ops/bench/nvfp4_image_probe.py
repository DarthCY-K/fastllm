#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""nvfp4_image_probe.py <base_url> <out.json> [tag]
纯文本包会在引擎侧报 `vision_config is incomplete`（返回空响应）；含视觉的 NVFP4 包应能识别颜色。
自造一张 96x96 纯色 PNG（不依赖 PIL），以 data URL 作为 image_url 发出，看回复是否命中颜色词。
"""
import base64, json, sys, urllib.request, urllib.error, zlib, struct

BASE = (sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8080").rstrip("/")
OUT = sys.argv[2] if len(sys.argv) > 2 else "/home/ai-agent/builds/upgrade-test/nvfp4-image-probe.json"
TAG = sys.argv[3] if len(sys.argv) > 3 else "nvfp4-image"
KEY = [l.split("=", 1)[1].strip().strip('"').strip("'")
       for l in open("/home/ai-agent/qwen38-0.2x.env", encoding="utf-8")
       if l.startswith("VLLM_API_KEY=")][0]
MODEL = "Qwen3.8-27B-W8A16"


def png_solid(w, h, rgb):
    raw = b"".join(b"\x00" + bytes(rgb) * w for _ in range(h))

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


res = {"tag": TAG, "base": BASE}
# 三色轮换，避免"猜一个词就中"：
cases = [("orange", (255, 140, 0), ["orange", "橙", "橘", "橙色", "橘色"]),
         ("green", (0, 160, 60), ["green", "绿", "绿色"]),
         ("purple", (128, 0, 200), ["purple", "紫", "紫色"])]
for name, rgb, keys in cases:
    png = png_solid(96, 96, rgb)
    url = "data:image/png;base64," + base64.b64encode(png).decode()
    body = {"model": MODEL, "max_tokens": 24, "temperature": 0, "stream": False,
            "chat_template_kwargs": {"enable_thinking": False},
            "messages": [{"role": "user", "content": [
                {"type": "text", "text": "What is the dominant color of this image? Answer with exactly one English color word."},
                {"type": "image_url", "image_url": {"url": url}}]}]}
    req = urllib.request.Request(BASE + "/v1/chat/completions",
        data=json.dumps(body).encode(), headers={"Authorization": "Bearer " + KEY,
                                                 "Content-Type": "application/json"})
    entry = {"expected": name, "png_bytes": len(png)}
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            j = json.loads(r.read().decode("utf-8", "replace"))
        msg = (j.get("choices") or [{}])[0].get("message") or {}
        txt = (msg.get("content") or "") + " " + (msg.get("reasoning_content") or "")
        entry.update({"http": 200, "text": txt.strip()[:160],
                      "usage": j.get("usage"),
                      "ok": any(k.lower() in txt.lower() for k in keys)})
    except urllib.error.HTTPError as e:
        entry.update({"http": e.code, "text": e.read().decode("utf-8", "replace")[:200], "ok": False})
    except Exception as e:
        entry.update({"http": -1, "text": repr(e)[:200], "ok": False})
    res.setdefault("cases", []).append(entry)
    print("%-8s http=%s ok=%s text=%r" % (name, entry.get("http"), entry.get("ok"), entry.get("text", "")[:80]), flush=True)

res["ok_all"] = all(c.get("ok") for c in res.get("cases", []))
json.dump(res, open(OUT, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
print("IMAGE_PROBE ok_all=%s saved=%s" % (res["ok_all"], OUT))
