#!/bin/bash
# rollback_dflashfix.sh — 回滚 DFlash 尾块修复：恢复 venv ftllm 至修复前包并重启。
set -u
V=/home/ai-agent/builds/fastllm-video-venv
PKG=$V/lib/python3.13/site-packages/ftllm
BK=$V/lib/python3.13/site-packages/ftllm.backup-20260914-pre-dflashfix
[ -d $BK ] || { echo NO_BACKUP; exit 2; }
rm -rf $PKG
cp -a $BK $PKG
echo "restored:"; md5sum $PKG/libfastllm_tools.so
sudo systemctl restart fastllm-qwen38-tp4
for i in $(seq 1 120); do
  code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8080/v1/models 2>/dev/null)
  if [ "$code" = "401" ] || [ "$code" = "200" ]; then echo "ROLLBACK_READY http=$code"; exit 0; fi
  sleep 5
done
echo ROLLBACK_NOT_READY
