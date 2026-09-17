#!/bin/bash
# rollback_chunk2048.sh — 恢复 pre-chunk2048 生产 argv（chunk 512 × interval 4）并重启验证。
set -u
W=/home/ai-agent/builds/upgrade-test
V=/home/ai-agent/builds/fastllm-video-venv
VPY=$V/bin/python

echo "===== ROLLBACK-CHUNK2048 START $(date '+%F %T') ====="
$VPY $W/scripts/rollback_chunk2048.py || exit 2
sudo systemctl restart fastllm-qwen38-tp4
RP=0
for i in $(seq 1 240); do
  code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8080/v1/models 2>/dev/null)
  if [ "$code" = "401" ] || [ "$code" = "200" ]; then RP=1; echo "READY after ~$((i*5))s"; break; fi
  sleep 5
done
systemctl show --no-pager fastllm-qwen38-tp4 -p MainPID -p NRestarts -p ActiveState -p SubState
echo "ROLLBACK_DONE ready=$RP"
echo "===== ROLLBACK-CHUNK2048 END $(date '+%F %T') ====="
