#!/bin/bash
# rollback_r12_gcfix.sh — 从 gcfix 回滚到现役 r12（ftllm.backup-20260922-pre-gcfix）+ 暖机
set -u
V=/home/ai-agent/builds/fastllm-video-venv
PKG=$V/lib/python3.13/site-packages/ftllm
BK=$V/lib/python3.13/site-packages/ftllm.backup-20260922-pre-gcfix
W=/home/ai-agent/builds/upgrade-test
[ -d $BK ] || { echo MISSING_BACKUP $BK; exit 2; }
rm -rf $PKG
cp -a $BK $PKG
M=$(md5sum $PKG/libfastllm_tools.so | cut -d' ' -f1)
echo "restored so md5=$M (expect 4fb02a30c1562e54438846e4c66f014c)"
[ "$M" = "4fb02a30c1562e54438846e4c66f014c" ] || echo "WARN: so md5 与 r12 基线不一致"
sudo systemctl restart fastllm-qwen38-tp4
RP=0
for i in $(seq 1 240); do
  code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8080/v1/models 2>/dev/null)
  if [ "$code" = "401" ] || [ "$code" = "200" ]; then RP=1; echo "PROD_READY ~$((i*5))s"; break; fi
  sleep 5
done
bash $W/scripts/warmup_prod.sh 360 2>&1 | tail -1
echo "ROLLBACK_GCFIX_DONE ready=$RP so=$M $(date '+%F %T')" > $W/rollback-gcfix.status
cat $W/rollback-gcfix.status
