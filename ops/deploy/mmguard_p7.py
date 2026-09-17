#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""mmguard_p7.py — 补充验收：无歧义单词版本（KITE204），冷算 + 重发（跳过复原）对。"""
import base64
import io
import json
import os
import time
import urllib.error
import urllib.request

from PIL import Image, ImageDraw, ImageFont

BASE = "http://127.0.0.1:8080"
MODEL = "Qwen3.8-27B-W8A16"
TAG = os.environ.get("MMGUARD_PROBE_TAG", "B0917")

KEY = ""
for _l in open("/home/ai-agent/qwen38-0.2x.env", encoding="utf-8"):
    _l = _l.strip()
    if _l.startswith("VLLM_API_KEY="):
        KEY = _l.split("=", 1)[1].strip().strip('"').strip("'")
        break
assert KEY, "no key"

PARA = ("普通段落用于填充上下文长度，这段文字没有特殊含义，仅用于构造独立前缀。"
        "记录编号 SEQ-%s。" % TAG)
FILL = PARA * 64


def make_image(word):
    img = Image.new("RGB", (512, 512), "white")
    d = ImageDraw.Draw(img)
    try:
        font = ImageFont.truetype(
            "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 76)
    except Exception:
        font = ImageFont.load_default()
    d.rectangle([70, 70, 300, 300], fill=(230, 160, 20))
    d.ellipse([330, 330, 460, 460], fill=(40, 40, 200))
    d.text((36, 420), word, fill=(0, 0, 0), font=font)
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode()


IMG_C = make_image("KITE204")

SYS = {"role": "system",
       "content": "你是严谨的读图助手：只描述你实际看到的内容。"}
M7 = [SYS,
      {"role": "user", "content": [
          {"type": "text", "text": FILL[:800] + "图C（短版）如下："},
          {"type": "image_url", "image_url": {"url": IMG_C}},
          {"type": "text", "text": "读出图中单词，只回复单词。"}]}]


def chat(stage, messages, max_tokens=32):
    body = {"model": MODEL, "messages": messages, "max_tokens": max_tokens,
            "temperature": 0.0, "stream": False,
            "chat_template_kwargs": {"enable_thinking": False}}
    req = urllib.request.Request(
        BASE + "/v1/chat/completions",
        data=json.dumps(body, ensure_ascii=False).encode("utf-8"),
        headers={"Content-Type": "application/json",
                 "Authorization": "Bearer " + KEY})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=900) as r:
            resp = json.loads(r.read().decode("utf-8"))
        text = (resp["choices"][0]["message"].get("content") or "").strip()
        rec = {"stage": stage, "code": 200,
               "t": round(time.time() - t0, 1), "answer": text[:120]}
    except urllib.error.HTTPError as e:
        rec = {"stage": stage, "code": e.code,
               "t": round(time.time() - t0, 1),
               "answer": e.read()[:150].decode("utf-8", "ignore")}
    print(json.dumps(rec, ensure_ascii=False), flush=True)
    ans = rec.get("answer", "").replace(" ", "").upper()
    print(json.dumps({"stage": stage,
                      "checks": {"KITE204": "KITE204" in ans}}, ensure_ascii=False),
          flush=True)
    return rec


if __name__ == "__main__":
    r7a = chat("P7a", M7)
    time.sleep(2)
    r7b = chat("P7b", M7)
    print("P7_DONE", flush=True)
