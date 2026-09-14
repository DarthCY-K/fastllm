#!/bin/bash
# rollback_backboneforce.sh — 回滚 backbone TP force：恢复 launcher 备份 + 重启 + 就绪等待。
set -u
L=/home/ai-agent/fastllm-video-repro/fastllm_prod_launch.py
BK=$L.bak-pre-backboneforce-20260914
[ -f "$BK" ] || { echo "NO BACKUP: $BK"; exit 1; }
cp -a "$BK" "$L"
grep -n 'FASTLLM_CUDA_DFLASH_TP_BACKBONE' "$L" | head -2
python3 -m py_compile "$L" && echo "launcher syntax OK"
sudo systemctl restart fastllm-qwen38-tp4
for i in $(seq 1 120); do
  code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8080/v1/models 2>/dev/null)
  if [ "$code" = "401" ] || [ "$code" = "200" ]; then echo "PROD_READY http=$code after ~$((i*3))s"; exit 0; fi
  sleep 3
done
echo "RESTART_FAILED"; exit 1
