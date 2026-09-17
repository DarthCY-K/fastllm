#!/bin/bash
# switch_to_chunk2048.sh — 转正「chunk 2048 × interval 16」组合（2026-09-17 窗口获胜配置）
#   就绪失败自动回滚。手动回滚：bash ops/deploy/rollback_chunk2048.sh
set -u
W=/home/ai-agent/builds/upgrade-test
V=/home/ai-agent/builds/fastllm-video-venv
VPY=$V/bin/python
R=/home/ai-agent/fastllm-video-repro
PLOG=$R/results/server-prod.service.log
EV=$W/wt-pooltrim/ops/evidence/chunk-window-20260917
mkdir -p $EV

echo "===== SWITCH-CHUNK2048 START $(date '+%F %T') ====="
echo "--- PHASE0 preflight ---"
[ -f $R/results/argv-prod-tp4.json ] || { echo NO_ARGV; exit 2; }
$VPY $W/scripts/apply_chunk2048.py || exit 2

echo "--- PHASE1 restart ---"
W0=$(wc -l < "$PLOG" 2>/dev/null || echo 0)
sudo systemctl restart fastllm-qwen38-tp4
RP=0
for i in $(seq 1 240); do
  code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8080/v1/models 2>/dev/null)
  if [ "$code" = "401" ] || [ "$code" = "200" ]; then RP=1; echo "HTTP_PORT_UP after ~$((i*5))s"; break; fi
  sleep 5
done

SMOKE=0
if [ "$RP" = "1" ]; then
  for i in $(seq 1 120); do
    if $VPY $W/scripts/mmguard_smoke.py > $EV/post-chunk-smoke.txt 2>&1; then SMOKE=1; break; fi
    sleep 5
  done
  cat $EV/post-chunk-smoke.txt
fi

if [ "$RP" != "1" ] || [ "$SMOKE" != "1" ]; then
  echo "NOT_READY (rp=$RP smoke=$SMOKE) -> AUTO ROLLBACK"
  $VPY $W/scripts/rollback_chunk2048.py
  sudo systemctl restart fastllm-qwen38-tp4
  for i in $(seq 1 240); do
    code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8080/v1/models 2>/dev/null)
    if [ "$code" = "401" ] || [ "$code" = "200" ]; then echo "ROLLED_BACK_READY after ~$((i*5))s"; break; fi
    sleep 5
  done
  echo "SWITCH_DONE status=ROLLED_BACK"
  exit 5
fi

echo "--- PHASE2 verify ---"
systemctl show --no-pager fastllm-qwen38-tp4 -p MainPID -p NRestarts -p ActiveState -p SubState
nvidia-smi --query-gpu=index,memory.used --format=csv,noheader
echo "-- startup markers in new window --"
tail -n +$((W0+1)) "$PLOG" | grep -aE "KV Cache Token limit|DFlash2\] enabled|Traceback|Error" | head -6
echo "SWITCH_DONE status=READY $(date '+%T')"
echo "===== SWITCH-CHUNK2048 END $(date '+%F %T') ====="
