#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""mmguard_probe.py — 视觉×前缀复原保护 验收探针（2026-09-17）。

用法：MMGUARD_PROBE_TAG=B0917 /home/ai-agent/builds/fastllm-video-venv/bin/python mmguard_probe.py
输出：stdout 每请求一行 JSON（stage/code/t/answer），随后一行 checks，最后 PROBE_DONE。

序列（串行、间隔2s，便于引擎日志按序对齐）：
  P4a/P4b 纯文本对照：长文本两连问 → 复原必须仍然生效（保护不得破坏文本路径）
  P1   冷算图像请求（图A 单词 CAT731）→ 期望冷预填、[Vision]、读出单词
  P2   P1 之上纯文本续问（图A位于复原区）→ 复原>0 且回答正确（mmcache 场景回归）
  P3   P2 之上追加新图B（DOG518）→ 修复前：复原+编造；修复后：跳过复原+[Vision]+正确
  P5   与 P1 完全相同的重发（图在复原区内的重发件）
  P6a/P6b 边界切图对（图像整体位于 512 复原边界之后）→ 修复前：重发全盲编造；修复后：跳过复原、仍正确
"""
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
ENV = "/home/ai-agent/qwen38-0.2x.env"
TAG = os.environ.get("MMGUARD_PROBE_TAG", time.strftime("%m%d%H%M"))

KEY = ""
for _l in open(ENV, encoding="utf-8"):
    _l = _l.strip()
    if _l.startswith("VLLM_API_KEY="):
        KEY = _l.split("=", 1)[1].strip().strip('"').strip("'")
        break
assert KEY, "VLLM_API_KEY not found"

PARA = ("普通段落用于填充上下文长度，这段文字没有特殊含义，仅用于构造独立前缀。"
        "记录编号 SEQ-%s。" % TAG)
FILL = PARA * 64


def filler(nchars):
    return FILL[:nchars]


def make_image(word, kind):
    img = Image.new("RGB", (512, 512), "white")
    d = ImageDraw.Draw(img)
    try:
        font = ImageFont.truetype(
            "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 76)
    except Exception:
        font = ImageFont.load_default()
    if kind == "circle":
        d.ellipse([80, 60, 340, 320], fill=(220, 30, 30))
        d.rectangle([360, 340, 470, 450], fill=(30, 30, 220))
    else:
        d.polygon([(256, 50), (60, 390), (452, 390)], fill=(30, 160, 60))
    d.text((36, 420), word, fill=(0, 0, 0), font=font)
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode()


IMG_A = make_image("CAT731", "circle")
IMG_B = make_image("DOG518", "triangle")

SYS = {"role": "system",
       "content": "你是严谨的读图助手：只描述你实际看到的内容。"}


def u(s):
    return {"role": "user", "content": s}


def up(parts):
    return {"role": "user", "content": parts}


def img(url):
    return {"type": "image_url", "image_url": {"url": url}}


def chat(stage, messages, max_tokens=48, timeout=900):
    body = {"model": MODEL, "messages": messages, "max_tokens": max_tokens,
            "temperature": 0.0, "stream": False,
            "chat_template_kwargs": {"enable_thinking": False}}
    req = urllib.request.Request(
        BASE + "/v1/chat/completions",
        data=json.dumps(body, ensure_ascii=False).encode("utf-8"),
        headers={"Content-Type": "application/json",
                 "Authorization": "Bearer " + KEY})
    t0 = time.time()
    if True:
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                resp = json.loads(r.read().decode("utf-8"))
            text = (resp["choices"][0]["message"].get("content") or "").strip()
            rec = {"stage": stage, "code": 200,
                   "t": round(time.time() - t0, 1), "answer": text[:200]}
        except urllib.error.HTTPError as e:
            rec = {"stage": stage, "code": e.code,
                   "t": round(time.time() - t0, 1),
                   "answer": e.read()[:200].decode("utf-8", "ignore")}
        except Exception as e:  # noqa: BLE001
            rec = {"stage": stage, "code": -1,
                   "t": round(time.time() - t0, 1),
                   "answer": type(e).__name__ + ":" + str(e)[:150]}
    print(json.dumps(rec, ensure_ascii=False), flush=True)
    return rec


def check(rec, *needles):
    ans = (rec.get("answer") or "").replace(" ", "").upper()
    checks = {n: (n.upper() in ans) for n in needles}
    print(json.dumps({"stage": rec["stage"], "checks": checks},
                     ensure_ascii=False), flush=True)


def main():
    # ---------- P4 纯文本对照 ----------
    F1 = filler(1560)
    M4A = [SYS, u("请阅读并记住口令序号：口令 PLAN-ZQ4417。" + F1 +
                  " 收到后回复『已收到口令』。")]
    r = chat("P4a", M4A)
    check(r, "已收到")
    M4B = M4A + [{"role": "assistant", "content": r.get("answer", "")},
                 u("刚才口令是什么？只回复口令本身。")]
    time.sleep(2)
    r = chat("P4b", M4B)
    check(r, "ZQ4417")

    # ---------- P1 冷图A ----------
    F3 = filler(560)
    F4 = filler(760)
    M1 = [SYS,
          u("前缀校验文本：" + F3),
          up([{"type": "text", "text": "图A如下："},
              img(IMG_A),
              {"type": "text", "text": "以上是图A。延续文本：" + F4},
              {"type": "text",
               "text": "问题：图A里有一个英文单词带三位数字，请只回复这个单词。"}])]
    time.sleep(2)
    r1 = chat("P1", M1, max_tokens=32)
    check(r1, "CAT731", "731")

    # ---------- P2 纯文本续问 ----------
    M2 = M1 + [{"role": "assistant", "content": r1.get("answer", "")},
               u("图A里的数字是几？只回复数字。")]
    time.sleep(2)
    r2 = chat("P2", M2, max_tokens=24)
    check(r2, "731")

    # ---------- P3 新图B ----------
    M3 = M2 + [{"role": "assistant", "content": r2.get("answer", "")},
               up([{"type": "text", "text": "这是第二张图（图B）："},
                   img(IMG_B),
                   {"type": "text",
                    "text": "图B里的单词是什么？只回复单词。"}])]
    time.sleep(2)
    r3 = chat("P3", M3, max_tokens=32)
    check(r3, "DOG518", "518")

    # ---------- P5 P1 重发 ----------
    time.sleep(2)
    r5 = chat("P5", M1, max_tokens=32)
    check(r5, "CAT731", "731")

    # ---------- P6 边界切图对（图像整体落在 512 复原边界之后 → 修复前全盲编造） ----------
    F5 = filler(800)
    M6 = [SYS,
          up([{"type": "text", "text": F5 + "图A（短版）如下："},
              img(IMG_A),
              {"type": "text", "text": "读出图中单词，只回复单词。"}])]
    time.sleep(2)
    r6a = chat("P6a", M6, max_tokens=32)
    check(r6a, "CAT731", "731")
    time.sleep(2)
    r6b = chat("P6b", M6, max_tokens=32)
    check(r6b, "CAT731", "731")

    print("PROBE_DONE tag=%s" % TAG, flush=True)


if __name__ == "__main__":
    main()
