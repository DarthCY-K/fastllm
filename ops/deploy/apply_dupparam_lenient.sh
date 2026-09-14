#!/usr/bin/env bash
# apply_dupparam_lenient.sh — 部署「工具调用重复同值参数宽容化」(2026-09-15)
# 幂等：repo 源文件 md5 预检 → 备份 → 同步 overlay-fix/overlay-r2/venv → 重启 → 就绪 → 部署件自检
set -eu
W=/home/ai-agent/builds/upgrade-test
PKG=/home/ai-agent/builds/fastllm-video-venv/lib/python3.13/site-packages/ftllm
VPY=/home/ai-agent/builds/fastllm-video-venv/bin/python
REL=openai_server/tool_parsers/qwen3coder_tool_parser.py
SRC=$W/repo/tools/fastllm_pytools/$REL
BAK=$PKG/$REL.wheelbak-20260915-pre-dupparam
EXPECT=b253557592c542888568f44374a258df
CHECK=$W/dupparam-20260915/check_deployed_dup_param.py
exec > >(tee -a $W/apply-dupparam.log) 2>&1
echo "===== APPLY DUPPARAM-LENIENT START $(date '+%F %T') ====="

M=$(md5sum "$SRC" | cut -d' ' -f1)
[ "$M" = "$EXPECT" ] || { echo "SRC_MD5_MISMATCH $M"; exit 2; }
grep -q "ignoring the duplicate" "$SRC" || { echo "NO_PATCH_MARKER"; exit 2; }

echo "--- PHASE1 backup venv file (if absent) ---"
[ -f "$BAK" ] || cp -p "$PKG/$REL" "$BAK"
echo "backup: $(md5sum "$BAK" | cut -d' ' -f1)"

echo "--- PHASE2 sync source -> overlays + venv ---"
for O in $W/overlay-fix/ftllm $W/overlay-r2/ftllm; do cp -p "$SRC" "$O/$REL"; done
cp -p "$SRC" "$PKG/$REL"
md5sum "$SRC" "$W/overlay-fix/ftllm/$REL" "$W/overlay-r2/ftllm/$REL" "$PKG/$REL"
$VPY -c "import ftllm.openai_server.tool_parsers.qwen3coder_tool_parser as m; print('import ok:', m.__file__)" || { echo IMPORT_FAIL; exit 4; }

echo "--- PHASE3 restart prod ---"
sudo systemctl restart fastllm-qwen38-tp4
RP=0
for i in $(seq 1 240); do
  code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8080/v1/models 2>/dev/null)
  if [ "$code" = "401" ] || [ "$code" = "200" ]; then RP=1; echo "PROD_READY after ~$((i*5))s"; break; fi
  sleep 5
done
if [ "$RP" != "1" ]; then echo "PROD_NOT_READY — rollback: bash $W/scripts/rollback_dupparam_lenient.sh"; exit 5; fi

echo "--- PHASE4 deployed-package check ---"
$VPY "$CHECK" || { echo "DEPLOYED_CHECK_FAIL — rollback: bash $W/scripts/rollback_dupparam_lenient.sh"; exit 6; }
PID=$(systemctl show fastllm-qwen38-tp4 -p MainPID --value)
echo "PID=$PID"
echo "APPLY_DUPPARAM_DONE ready=$RP pid=$PID" > $W/apply-dupparam.status
echo "===== APPLY DUPPARAM-LENIENT END $(date '+%F %T') ====="
