#!/bin/bash
# flip_autostart.sh — 开机自启翻转：旧 vLLM 禁用，FastLLM 生产启用。
set -u
echo "=== 翻转前 ==="
for u in fastllm-qwen38-tp4 qwen38-0.2x-tp4; do echo "$u: $(systemctl is-enabled $u 2>&1)"; done
echo "=== 执行 ==="
sudo systemctl disable qwen38-0.2x-tp4 2>&1 | tail -1
sudo systemctl enable fastllm-qwen38-tp4 2>&1 | tail -1
sudo systemctl daemon-reload
echo "=== 翻转后 ==="
for u in fastllm-qwen38-tp4 qwen38-0.2x-tp4; do echo "$u: $(systemctl is-enabled $u 2>&1)"; done
echo "FLIP_DONE"
