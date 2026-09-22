#!/bin/bash
# rollback_r3.sh — 回滚 r3：恢复 venv ftllm 至 r3 之前的包（r2+dflashfix+dupparam）并重启。
set -u
W=/home/ai-agent/builds/upgrade-test
V=/home/ai-agent/builds/fastllm-video-venv
PKG=$V/lib/python3.13/site-packages/ftllm
BK=$V/lib/python3.13/site-packages/ftllm.backup-20260915-pre-r3
PLOG=/home/ai-agent/fastllm-video-repro/results/server-prod.service.log
[ -d $BK ] || { echo NO_BACKUP; exit 2; }
echo "===== ROLLBACK-R3 START $(date '+%F %T') ====="
rm -rf $PKG
cp -a $BK $PKG
echo "restored:"; md5sum $PKG/libfastllm_tools.so
W0=$(wc -l < $PLOG 2>/dev/null || echo 0)
sudo systemctl restart fastllm-qwen38-tp4
for i in $(seq 1 120); do
  code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8080/v1/models 2>/dev/null)
  if [ "$code" = "401" ] || [ "$code" = "200" ]; then echo "ROLLBACK_READY http=$code after ~$((i*5))s"; exit 0; fi
  sleep 5
done
echo ROLLBACK_NOT_READY
