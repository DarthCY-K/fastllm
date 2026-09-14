#!/usr/bin/env bash
# rollback_dupparam_lenient.sh — 回滚「工具调用重复同值参数宽容化」(2026-09-15)
# 还原 venv 中被替换的 qwen3coder_tool_parser.py，重启生产并等待就绪。
set -u
PKG=/home/ai-agent/builds/fastllm-video-venv/lib/python3.13/site-packages/ftllm
REL=openai_server/tool_parsers/qwen3coder_tool_parser.py
BAK=$PKG/$REL.wheelbak-20260915-pre-dupparam
W=/home/ai-agent/builds/upgrade-test
exec > >(tee -a $W/rollback-dupparam.log) 2>&1
echo "===== ROLLBACK DUPPARAM-LENIENT START $(date '+%F %T') ====="
[ -f "$BAK" ] || { echo "NO_BACKUP $BAK"; exit 2; }
cp -p "$BAK" "$PKG/$REL"
echo "restored md5: $(md5sum "$PKG/$REL" | cut -d' ' -f1)"
grep -c "ignoring the duplicate" "$PKG/$REL" && { echo "STILL_PATCHED"; exit 3; }
sudo systemctl restart fastllm-qwen38-tp4
RP=0
for i in $(seq 1 240); do
  code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8080/v1/models 2>/dev/null)
  if [ "$code" = "401" ] || [ "$code" = "200" ]; then RP=1; echo "PROD_READY after ~$((i*5))s"; break; fi
  sleep 5
done
PID=$(systemctl show fastllm-qwen38-tp4 -p MainPID --value)
echo "PID=$PID"
echo "ROLLBACK_DUPPARAM_DONE ready=$RP" > $W/rollback-dupparam.status
echo "===== ROLLBACK DUPPARAM-LENIENT END $(date '+%F %T') ====="
