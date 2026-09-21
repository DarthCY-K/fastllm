#!/bin/bash
# warmup_on_start.sh — 引擎每次启动后自动暖机（把 SSD 首请求"恢复/校验"开销移出用户路径）
# 调用：
#   systemd ExecStartPost：warmup_on_start.sh        → fork 后台执行体后立即返回（不阻塞 systemd）
#   手动前台执行：         warmup_on_start.sh --run   → 直接执行（调试用）
# 永不返回非 0；状态 → /home/ai-agent/ops/warmup_state.json；日志 → /home/ai-agent/ops/warmup.log
set -u
OPS=/home/ai-agent/ops
ENVFILE=/home/ai-agent/qwen38-0.2x.env
STORE=/var/cache/lmcache/prefix_ssd_prod
API=http://127.0.0.1:8080
UNIT=fastllm-qwen38-tp4
REQ_TIMEOUT=${WARMUP_TIMEOUT:-900}

if [ "${1:-}" != "--run" ]; then
    setsid nohup bash "$0" --run >/dev/null 2>&1 < /dev/null &
    exit 0
fi

mkdir -p "$OPS" 2>/dev/null
LOCK="$OPS/.warmup.lock"
LOG="$OPS/warmup.log"
exec 9>"$LOCK" || exit 0
flock -n 9 || { echo "[$(date '+%F %T')] skip: another warmup is running" >> "$LOG"; exit 0; }

log(){ echo "[$(date '+%F %T')] $*" >> "$LOG"; }
st(){ python3 "$OPS/warmup_state.py" "$@"; }

t0=$(date +%s)
MID=$(systemctl show -p MainPID --value "$UNIT" 2>/dev/null || echo 0)
SB=$(du -sb "$STORE" 2>/dev/null | cut -f1); SB=${SB:-0}
EXP=$(python3 -c "print(round(${SB}/295e6))" 2>/dev/null || echo 0)
st state=waiting_ready started=$t0 engine_pid=$MID store_bytes=$SB expected_s=$EXP rc= note=waiting_engine_ready ready_s= elapsed_s= finished=
log "start: pid=$MID store_bytes=$SB expected_s=$EXP"

ready_ok=0
ready=0
for i in $(seq 1 90); do
    code=$(curl -s -o /dev/null -m 3 -w '%{http_code}' "$API/v1/models" 2>/dev/null)
    if [ "$code" = "401" ] || [ "$code" = "200" ]; then ready_ok=1; ready=$(( $(date +%s) - t0 )); break; fi
    sleep 5
done
if [ "$ready_ok" != "1" ]; then
    st state=failed finished=$(date +%s) note=engine_not_ready_within_450s
    log "failed: engine not ready within 450s"; exit 0
fi

st state=warming ready_s=$ready
log "ready after ${ready}s; sending warmup request"
K=$(python3 - "$ENVFILE" <<'PYEOF'
import sys
for line in open(sys.argv[1]):
    line = line.strip()
    if line.startswith("VLLM_API_KEY="):
        print(line.split("=", 1)[1].strip().strip('"').strip("'"))
        break
PYEOF
)
printf '{"model":"Qwen3.8-27B","messages":[{"role":"user","content":"warmup"}],"max_tokens":4,"temperature":0}' > /tmp/warmup_ping.json
t1=$(date +%s)
curl -s -o /tmp/warmup_resp.json -m "$REQ_TIMEOUT" -H "Authorization: Bearer $K" -H 'Content-Type: application/json' -d @/tmp/warmup_ping.json "$API/v1/chat/completions"
rc=$?
t2=$(date +%s)
if [ "$rc" = "0" ]; then
    st state=done finished=$t2 elapsed_s=$((t2-t1)) rc=0 note=ok
    log "done: rc=0 warmup_elapsed=$((t2-t1))s total=$((t2-t0))s"
else
    st state=failed finished=$t2 elapsed_s=$((t2-t1)) rc=$rc note=curl_rc_$rc
    log "done: rc=$rc warmup_elapsed=$((t2-t1))s total=$((t2-t0))s"
fi
exit 0
