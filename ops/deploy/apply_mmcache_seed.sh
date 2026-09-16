#!/bin/bash
# apply_mmcache_seed.sh — deploy multimodal prefix-cache seeding fix (2026-09-16)
# Source of truth: DarthCY-K/fastllm sm75-2080Ti @ tag mmcache-prod-20260916
# Idempotent: md5 precheck, backup, sync, restart, readiness wait.
set -euo pipefail
W=/home/ai-agent/builds/upgrade-test
V=/home/ai-agent/builds/fastllm-video-venv/lib/python3.13/site-packages/ftllm
SRC_SO=$W/overlay-mmfix/ftllm/libfastllm_tools.so
EXPECT=de41af83cefee14cd829bd63dec40ecd

[ -f "$SRC_SO" ] || { echo "MISSING $SRC_SO"; exit 1; }
have=$(md5sum "$SRC_SO" | cut -d' ' -f1)
[ "$have" = "$EXPECT" ] || { echo "SRC_MD5_MISMATCH $have"; exit 1; }

cur=$(md5sum "$V/libfastllm_tools.so" | cut -d' ' -f1)
if [ "$cur" = "$EXPECT" ]; then echo "ALREADY_DEPLOYED"; exit 0; fi

bak=$V/libfastllm_tools.so.wheelbak-20260916-pre-mmcache
[ -f "$bak" ] || cp -p "$V/libfastllm_tools.so" "$bak"
cp -p "$SRC_SO" "$V/libfastllm_tools.so"

sudo systemctl restart fastllm-qwen38-tp4
code=000
for i in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8080/v1/models 2>/dev/null || true)
  [ "$code" = "401" ] && break
  sleep 3
done
[ "$code" = "401" ] || { echo "READY_TIMEOUT code=$code"; exit 2; }
md5sum "$V/libfastllm_tools.so"
echo "APPLY_OK"
