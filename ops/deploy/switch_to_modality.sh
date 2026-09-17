#!/bin/bash
# switch_to_modality.sh — 部署「HF 视觉塔图片能力上报」修复（2026-09-17）
#   来源：上游 PR #741（只摘 fastllm_model.py 两处 hunk）
#   就绪失败自动回滚到 pre-modality 备份。
#   手动回滚：bash ops/deploy/rollback_modality.sh
set -u
W=/home/ai-agent/builds/upgrade-test
V=/home/ai-agent/builds/fastllm-video-venv
PKG=$V/lib/python3.13/site-packages/ftllm
SRC=$W/wt-pooltrim/tools/fastllm_pytools/openai_server/fastllm_model.py
DST=$PKG/openai_server/fastllm_model.py
BAK=$DST.wheelbak-20260917-pre-modality
R=/home/ai-agent/fastllm-video-repro
PLOG=$R/results/server-prod.service.log
EV=$W/wt-pooltrim/ops/evidence/modality-20260917
VPY=$V/bin/python

echo "===== SWITCH-MODALITY START $(date '+%F %T') ====="
echo "--- PHASE0 preflight ---"
[ -f "$SRC" ] || { echo NO_SRC; exit 2; }
grep -q "_supports_image_input" "$SRC" || { echo NO_FIX_MARKER_IN_SRC; exit 2; }
PYTHONPYCACHEPREFIX=/tmp/pycache $VPY -m py_compile "$SRC" || { echo PY_COMPILE_FAIL; exit 2; }
mkdir -p "$EV"

echo "--- PHASE1 before-evidence ---"
KEY=$(grep -h ^VLLM_API_KEY= /home/ai-agent/qwen38-0.2x.env | cut -d= -f2- | tr -d '\r\n')
curl -s -m 20 -H "Authorization: Bearer $KEY" http://127.0.0.1:8080/v1/models > "$EV/models-before.json" 2>/dev/null || true
grep -oE '"input_modalities":\[[^]]*\]' "$EV/models-before.json" || echo "(before: no field)"

echo "--- PHASE2 backup+install ---"
if [ ! -f "$BAK" ]; then cp -a "$DST" "$BAK" && echo "backup -> $BAK"; else echo "backup exists -> $BAK"; fi
cp -f "$SRC" "$DST"
md5sum "$SRC" "$DST"

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
PROBE=0
if [ "$RP" = "1" ]; then
  for i in $(seq 1 120); do
    if $VPY $W/scripts/mmguard_smoke.py > $EV/smoke-after.txt 2>&1; then SMOKE=1; break; fi
    sleep 5
  done
  cat $EV/smoke-after.txt
  if [ "$SMOKE" = "1" ]; then
    for i in $(seq 1 24); do
      if $VPY $W/wt-pooltrim/ops/deploy/modality_probe.py > $EV/modality-probe.txt 2>&1; then PROBE=1; break; fi
      sleep 5
    done
    cat $EV/modality-probe.txt
  fi
fi

if [ "$RP" != "1" ] || [ "$SMOKE" != "1" ] || [ "$PROBE" != "1" ]; then
  echo "NOT_READY (rp=$RP smoke=$SMOKE probe=$PROBE) -> AUTO ROLLBACK"
  cp -f "$BAK" "$DST"
  sudo systemctl restart fastllm-qwen38-tp4
  for i in $(seq 1 240); do
    code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8080/v1/models 2>/dev/null)
    if [ "$code" = "401" ] || [ "$code" = "200" ]; then echo "ROLLED_BACK_READY after ~$((i*5))s"; break; fi
    sleep 5
  done
  echo "SWITCH_DONE status=ROLLED_BACK py=$(md5sum $DST | cut -d' ' -f1)"
  exit 5
fi

echo "--- PHASE4 verify ---"
systemctl show --no-pager fastllm-qwen38-tp4 -p MainPID -p NRestarts -p ActiveState -p SubState
nvidia-smi --query-gpu=index,memory.used --format=csv,noheader
curl -s -m 20 -H "Authorization: Bearer $KEY" http://127.0.0.1:8080/v1/models > "$EV/models-after.json" 2>/dev/null || true
grep -oE '"input_modalities":\[[^]]*\]' "$EV/models-after.json" || echo "(after: no field)"
echo "-- startup markers in new window --"
tail -n +$((W0+1)) "$PLOG" | grep -aE "KV Cache Token limit|DFlash2\] enabled|Traceback|Error" | head -6
echo "SWITCH_DONE status=READY py=$(md5sum $DST | cut -d' ' -f1)"
echo "===== SWITCH-MODALITY END $(date '+%F %T') ====="
