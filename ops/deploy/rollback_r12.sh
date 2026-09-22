#!/bin/bash
# rollback_r12.sh — 从 r12 回滚到 pre-r12（lazy-recover 线，r11 生产）venv + 暖机
set -u
V=/home/ai-agent/builds/fastllm-video-venv
PKG=$V/lib/python3.13/site-packages/ftllm
BK=$V/lib/python3.13/site-packages/ftllm.backup-20260922-pre-r12
W=/home/ai-agent/builds/upgrade-test
[ -d $BK ] || { echo MISSING_BACKUP $BK; exit 2; }
rm -rf $PKG
cp -a $BK $PKG
M=$(md5sum $PKG/libfastllm_tools.so | cut -d' ' -f1); echo "restored so md5=$M (expect 319a3e34dafb063a6f1d2d28df33e2f8)"
L=/home/ai-agent/fastllm-video-repro/fastllm_prod_launch.py
LBK=$L.bak-pre-r12-triton-20260922
if [ -f $LBK ]; then
  cp -a $LBK $L && echo "launcher restored (Triton block removed): $L"
  python3 -m py_compile $L && echo "launcher compile OK"
else
  echo "WARN: launcher backup missing ($LBK) — 手动移除 FASTLLM_CUDA_TRITON 块"
fi
sudo systemctl restart fastllm-qwen38-tp4
RP=0
for i in $(seq 1 240); do
  code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8080/v1/models 2>/dev/null)
  if [ "$code" = "401" ] || [ "$code" = "200" ]; then RP=1; echo "PROD_READY ~$((i*5))s"; break; fi
  sleep 5
done
bash $W/scripts/warmup_prod.sh 360
echo "ROLLBACK_R12_DONE ready=$RP so=$M"
