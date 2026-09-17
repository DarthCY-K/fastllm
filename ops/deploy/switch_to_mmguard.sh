#!/bin/bash
# switch_to_mmguard.sh — 部署「视觉复原保护」版本（2026-09-17）
#   就绪失败自动回滚到 pre-mmguard 备份。
#   手动回滚：bash scripts/rollback_mmguard.sh
set -u
W=/home/ai-agent/builds/upgrade-test
V=/home/ai-agent/builds/fastllm-video-venv
PKG=$V/lib/python3.13/site-packages/ftllm
R=/home/ai-agent/fastllm-video-repro
PLOG=$R/results/server-prod.service.log
ART=$W/build-mmguard/tools/ftllm/libfastllm_tools.so
BK=$PKG/libfastllm_tools.so.wheelbak-20260917-pre-mmguard
VPY=$V/bin/python

echo "===== SWITCH-MMGUARD START $(date '+%F %T') ====="
echo "--- PHASE0 preflight ---"
[ -f "$ART" ] || { echo NO_ARTIFACT; exit 2; }
M=$(md5sum "$ART" | cut -d' ' -f1); echo "artifact md5=$M"
strings -a "$ART" | grep -q "FT_QWEN35_MM_RESTORE_GUARD" || { echo NO_GUARD_ENV_MARKER; exit 2; }
strings -a "$ART" | grep -q "prefix restore skipped" || { echo NO_GUARD_LOG_MARKER; exit 2; }
strings -a "$ART" | grep -q "idle big-buffer trim" || { echo NO_POOLTRIM_CARRY; exit 2; }

echo "--- PHASE1 backup+install ---"
if [ ! -f "$BK" ]; then cp -a "$PKG/libfastllm_tools.so" "$BK" && echo "backup -> $BK"; else echo "backup exists -> $BK"; fi
cp -f "$ART" "$PKG/libfastllm_tools.so"
md5sum "$ART" "$PKG/libfastllm_tools.so"

echo "--- PHASE2 restart ---"
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
    if $VPY $W/scripts/mmguard_smoke.py > $W/switch-mmguard-smoke.txt 2>&1; then SMOKE=1; break; fi
    sleep 5
  done
  cat $W/switch-mmguard-smoke.txt
fi

if [ "$RP" != "1" ] || [ "$SMOKE" != "1" ]; then
  echo "NOT_READY (rp=$RP smoke=$SMOKE) -> AUTO ROLLBACK"
  cp -f "$BK" "$PKG/libfastllm_tools.so"
  sudo systemctl restart fastllm-qwen38-tp4
  for i in $(seq 1 240); do
    code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8080/v1/models 2>/dev/null)
    if [ "$code" = "401" ] || [ "$code" = "200" ]; then echo "ROLLED_BACK_READY after ~$((i*5))s"; break; fi
    sleep 5
  done
  echo "SWITCH_DONE status=ROLLED_BACK so=$(md5sum $PKG/libfastllm_tools.so | cut -d' ' -f1)"
  exit 5
fi

echo "--- PHASE3 verify ---"
systemctl show --no-pager fastllm-qwen38-tp4 -p MainPID -p NRestarts -p ActiveState -p SubState
nvidia-smi --query-gpu=index,memory.used --format=csv,noheader
echo "-- startup markers in new window --"
tail -n +$((W0+1)) "$PLOG" | grep -aE "KV Cache Token limit|DFlash2\] enabled|Traceback|Error" | head -6
echo "SWITCH_DONE status=READY so=$(md5sum $PKG/libfastllm_tools.so | cut -d' ' -f1)"
echo "===== SWITCH-MMGUARD END $(date '+%F %T') ====="
