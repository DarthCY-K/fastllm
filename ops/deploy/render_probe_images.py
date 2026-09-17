#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""render_probe_images.py — 把 mmguard_probe 的 IMG_A/IMG_B 落盘成 PNG 供人工核对。"""
import base64
import importlib.util
import sys

spec = importlib.util.spec_from_file_location(
    "mmprobe", "/home/ai-agent/builds/upgrade-test/scripts/mmguard_probe.py")
mm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mm)

for name, dataurl in (("img_a", mm.IMG_A), ("img_b", mm.IMG_B)):
    path = "/home/ai-agent/builds/upgrade-test/%s.png" % name
    with open(path, "wb") as f:
        f.write(base64.b64decode(dataurl.split(",", 1)[1]))
    print("WROTE", path)
print("RENDER_DONE")
