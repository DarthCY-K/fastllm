#!/bin/bash
# switch_to_pooltrim.sh — 部署主修（请求结束回收空闲大块）并保留 [MTrace] 观察。
#   TRACE=1|0  是否保留 FT_CUDA_ALLOC_TRACE（默认 1，验证期留开）
#   就绪失败自动回滚到 pre-pooltrim 备份。
# 手动回滚：bash scripts/rollback_pooltrim.sh
set -u
W=/home/ai-agent/builds/upgrade-test
V=/home/ai-agent/builds/fastllm-video-venv
PKG=$V/lib/python3.13/site-packages/ftllm
R=/home/ai-agent/fastllm-video-repro
PLOG=$R/results/server-prod.service.log
ART=$W/build-pooltrim/tools/ftllm/libfastllm_tools.so
BK=$PKG/libfastllm_tools.so.wheelbak-20260916-pre-pooltrim
TRACE=${TRACE:-1}
VPY=$V/bin/python

echo "===== SWITCH-POOLTRIM START $(date '+%F %T') ====="
echo "--- PHASE0 preflight ---"
[ -f "$ART" ] || { echo NO_ARTIFACT; exit 2; }
M=$(md5sum "$ART" | cut -d' ' -f1); echo "artifact md5=$M"
strings -a "$ART" | grep -q "idle big-buffer trim" || { echo NO_TRIM_MARKER; exit 2; }
strings -a "$ART" | grep -q "FT_QWEN35_REQUEST_POOL_TRIM" || { echo NO_ENV_MARKER; exit 2; }

echo "--- PHASE1 backup+install ---"
if [ ! -f "$BK" ]; then cp -a "$PKG/libfastllm_tools.so" "$BK" && echo "backup -> $BK"; else echo "backup exists -> $BK"; fi
cp -f "$ART" "$PKG/libfastllm_tools.so"
md5sum "$ART" "$PKG/libfastllm_tools.so"

echo "--- PHASE2 env (TRACE=$TRACE; trim 默认开) ---"
if [ "$TRACE" = "1" ]; then
  sudo systemctl set-environment FT_CUDA_ALLOC_TRACE=1 FT_CUDA_ALLOC_TRACE_MIN_MB=1
else
  sudo systemctl unset-environment FT_CUDA_ALLOC_TRACE FT_CUDA_ALLOC_TRACE_MIN_MB
fi
sudo systemctl unset-environment FT_CUDA_ALLOC_TRACE_STACK

echo "--- PHASE3 restart ---"
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
    if $VPY $W/scripts/alloc_trace_smoke.py > $W/switch-pooltrim-smoke.txt 2>&1; then SMOKE=1; break; fi
    sleep 5
  done
  cat $W/switch-pooltrim-smoke.txt
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

echo "--- PHASE4 verify ---"
systemctl show --no-pager fastllm-qwen38-tp4 -p MainPID -p NRestarts -p ActiveState -p SubState
nvidia-smi --query-gpu=index,memory.used --format=csv,noheader
echo "-- trim/startup markers in new window --"
tail -n +$((W0+1)) "$PLOG" | grep -ac "idle big-buffer trim" | sed 's/^/trim_lines=/'
tail -n +$((W0+1)) "$PLOG" | grep -aE "KV Cache Token limit|DFlash2\] enabled|Traceback|Error" | head -6
echo "SWITCH_DONE status=READY so=$(md5sum $PKG/libfastllm_tools.so | cut -d' ' -f1)"
echo "===== SWITCH-POOLTRIM END $(date '+%F %T') ====="
