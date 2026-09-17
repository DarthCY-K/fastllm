#!/bin/bash
# rollback_mmguard.sh — 恢复 pre-mmguard 生产 .so（pool-trim 版，9889a31b）并重启验证。
set -u
V=/home/ai-agent/builds/fastllm-video-venv/lib/python3.13/site-packages/ftllm
BAK=$V/libfastllm_tools.so.wheelbak-20260917-pre-mmguard
EXPECT=9889a31b22b9b7d40329ce0880d0fd7f

echo "===== ROLLBACK-MMGUARD START $(date '+%F %T') ====="
[ -f "$BAK" ] || { echo NO_BACKUP; exit 2; }
have=$(md5sum "$BAK" | cut -d' ' -f1)
[ "$have" = "$EXPECT" ] || { echo "BACKUP_MD5_MISMATCH $have"; exit 2; }
cp -p "$BAK" "$V/libfastllm_tools.so"

sudo systemctl restart fastllm-qwen38-tp4
RP=0
for i in $(seq 1 240); do
  code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8080/v1/models 2>/dev/null)
  if [ "$code" = "401" ] || [ "$code" = "200" ]; then RP=1; echo "READY after ~$((i*5))s"; break; fi
  sleep 5
done
systemctl show --no-pager fastllm-qwen38-tp4 -p MainPID -p NRestarts -p ActiveState -p SubState
echo "ROLLBACK_DONE ready=$RP so=$(md5sum $V/libfastllm_tools.so | cut -d' ' -f1)"
echo "===== ROLLBACK-MMGUARD END $(date '+%F %T') ====="
