#!/bin/bash
# rollback_mmcache_seed.sh — restore pre-mmcache production so + restart (2026-09-16)
set -euo pipefail
V=/home/ai-agent/builds/fastllm-video-venv/lib/python3.13/site-packages/ftllm
BAK=$V/libfastllm_tools.so.wheelbak-20260916-pre-mmdiag
EXPECT=06779c196df5a944c95dd25fde8d491f

[ -f "$BAK" ] || { echo "MISSING backup $BAK"; exit 1; }
have=$(md5sum "$BAK" | cut -d' ' -f1)
[ "$have" = "$EXPECT" ] || { echo "BACKUP_MD5_MISMATCH $have"; exit 1; }
cp -p "$BAK" "$V/libfastllm_tools.so"

sudo systemctl restart fastllm-qwen38-tp4
code=000
for i in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8080/v1/models 2>/dev/null || true)
  [ "$code" = "401" ] && break
  sleep 3
done
[ "$code" = "401" ] || { echo "READY_TIMEOUT code=$code"; exit 2; }
md5sum "$V/libfastllm_tools.so"
echo "ROLLBACK_OK"
