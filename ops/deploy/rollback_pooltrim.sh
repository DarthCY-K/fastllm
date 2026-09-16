#!/bin/bash
# rollback_pooltrim.sh — 恢复 pre-pooltrim 生产 .so（alloc-trace 版）并重启验证。
set -u
V=/home/ai-agent/builds/fastllm-video-venv
PKG=$V/lib/python3.13/site-packages/ftllm
BK=$PKG/libfastllm_tools.so.wheelbak-20260916-pre-pooltrim

echo "===== ROLLBACK-POOLTRIM START $(date '+%F %T') ====="
[ -f "$BK" ] || { echo NO_BACKUP; exit 2; }
cp -f "$BK" "$PKG/libfastllm_tools.so"
md5sum "$PKG/libfastllm_tools.so"
sudo systemctl restart fastllm-qwen38-tp4
RP=0
for i in $(seq 1 240); do
  code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8080/v1/models 2>/dev/null)
  if [ "$code" = "401" ] || [ "$code" = "200" ]; then RP=1; echo "READY after ~$((i*5))s"; break; fi
  sleep 5
done
systemctl show --no-pager fastllm-qwen38-tp4 -p MainPID -p NRestarts -p ActiveState -p SubState
echo "ROLLBACK_DONE ready=$RP so=$(md5sum $PKG/libfastllm_tools.so | cut -d' ' -f1)"
echo "===== ROLLBACK-POOLTRIM END $(date '+%F %T') ====="
