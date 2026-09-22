#!/bin/bash
# rollback_r13.sh — 从 r13 回滚到 pre-r13（r12+gcfix+export 线，生产 so=1747548d）venv + 暖机
set -u
V=/home/ai-agent/builds/fastllm-video-venv
PKG=$V/lib/python3.13/site-packages/ftllm
BK=$V/lib/python3.13/site-packages/ftllm.backup-20260922-pre-r13
W=/home/ai-agent/builds/upgrade-test
[ -d $BK ] || { echo MISSING_BACKUP $BK; exit 2; }
rm -rf $PKG
cp -a $BK $PKG
M=$(md5sum $PKG/libfastllm_tools.so | cut -d" " -f1); echo "restored so md5=$M (expect 1747548d1553aa416591cc96e847c568)"
sudo systemctl restart fastllm-qwen38-tp4
RP=0
for i in $(seq 1 240); do
  code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8080/v1/models 2>/dev/null)
  if [ "$code" = "401" ] || [ "$code" = "200" ]; then RP=1; echo "PROD_READY ~$((i*5))s"; break; fi
  sleep 5
done
bash $W/scripts/warmup_prod.sh 360
echo "ROLLBACK_R13_DONE ready=$RP so=$M"
