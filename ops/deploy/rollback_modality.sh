#!/bin/bash
# rollback_modality.sh — 恢复 pre-modality 的 fastllm_model.py（mmproj-only 判定）并重启验证。
set -u
V=/home/ai-agent/builds/fastllm-video-venv/lib/python3.13/site-packages/ftllm
DST=$V/openai_server/fastllm_model.py
BAK=$DST.wheelbak-20260917-pre-modality

echo "===== ROLLBACK-MODALITY START $(date '+%F %T') ====="
[ -f "$BAK" ] || { echo NO_BACKUP; exit 2; }
cp -p "$BAK" "$DST"
sudo systemctl restart fastllm-qwen38-tp4
RP=0
for i in $(seq 1 240); do
  code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8080/v1/models 2>/dev/null)
  if [ "$code" = "401" ] || [ "$code" = "200" ]; then RP=1; echo "READY after ~$((i*5))s"; break; fi
  sleep 5
done
systemctl show --no-pager fastllm-qwen38-tp4 -p MainPID -p NRestarts -p ActiveState -p SubState
echo "ROLLBACK_DONE ready=$RP py=$(md5sum $DST | cut -d' ' -f1)"
echo "===== ROLLBACK-MODALITY END $(date '+%F %T') ====="
