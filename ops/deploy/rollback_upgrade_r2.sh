#!/bin/bash
# rollback_upgrade_r2.sh — 恢复 r2 切换前的 venv ftllm 备份（= r1 生产包）
set -u
V=/home/ai-agent/builds/fastllm-video-venv
PKG=$V/lib/python3.13/site-packages/ftllm
BK=$V/lib/python3.13/site-packages/ftllm.backup-20260914-pre-r2
[ -d $BK ] || { echo NO_BACKUP; exit 2; }
sudo systemctl stop fastllm-qwen38-tp4
sleep 3
rm -rf ${PKG}.rollback-tmp && mv $PKG ${PKG}.rollback-tmp
cp -a $BK $PKG
sudo systemctl start fastllm-qwen38-tp4
for i in $(seq 1 120); do
  code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8080/v1/models 2>/dev/null)
  if [ "$code" = "401" ] || [ "$code" = "200" ]; then echo "ROLLBACK_READY http=$code"; exit 0; fi
  sleep 5
done
echo ROLLBACK_NOT_READY
