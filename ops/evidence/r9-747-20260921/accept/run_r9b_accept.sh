#!/bin/bash
# run_r9b_accept.sh — r9b 验收套餐（2026-09-21）
# A 现产基线(8080) → 停生产 → B r9b 栈(8081) → C 功能探针 → D 尾块 → E 长文针测 → 拆栈 → 恢复生产
set -u
trap "" HUP
W=/home/ai-agent/builds/upgrade-test
V=/home/ai-agent/builds/fastllm-video-venv
VPY=$V/bin/python
LOG=$W/r9b-accept.log
STATUS=$W/r9b-accept.status
exec > >(tee -a "$LOG") 2>&1
echo "========= R9B ACCEPT START $(date '+%F %T') ========="
PROD_OK=0
restore_on_exit() { systemctl is-active --quiet fastllm-qwen38-tp4 || { echo "TRAP: restoring prod"; sudo systemctl start fastllm-qwen38-tp4; }; }
trap restore_on_exit EXIT
stop_prod() { echo "--- stop prod $(date '+%T') ---"; sudo systemctl stop fastllm-qwen38-tp4; for i in $(seq 1 40); do systemctl is-active --quiet fastllm-qwen38-tp4 || break; sleep 1; done; sleep 4; }
start_prod() { echo "--- restore prod $(date '+%T') ---"; sudo systemctl start fastllm-qwen38-tp4; PROD_OK=0; for i in $(seq 1 240); do code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8080/v1/models 2>/dev/null); if [ "$code" = "401" ] || [ "$code" = "200" ]; then PROD_OK=1; echo "PROD_READY ~$((i*5))s"; break; fi; sleep 5; done; echo "prod_ready=$PROD_OK"; }

echo "--- PHASE A: prod baseline probes (8080, r8) $(date '+%T') ---"
$VPY $W/trial_probe2.py http://127.0.0.1:8080 $W/accept-prod-probe.json || echo "PROD_PROBE_FAIL"
echo "prod tail64: $($VPY $W/scripts/tail64_probe.py http://127.0.0.1:8080 2>&1 | tail -1)"

stop_prod
echo "--- PHASE B: candidate stack (r9b, accept argv) $(date '+%T') ---"
ARGV_FILE=argv-r9b-accept.json DFLASH_TB=force $VPY $W/fastllm_test_launch_r9b.py > $W/accept-stack.log 2>&1 &
TPID=$!
echo $TPID > $W/accept-stack.pid
READY=0
for i in $(seq 1 72); do
  code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8081/v1/models 2>/dev/null)
  if [ "$code" = "401" ] || [ "$code" = "200" ]; then READY=1; echo "READY ~$((i*5))s"; break; fi
  kill -0 $TPID 2>/dev/null || { echo "DIED ~$((i*5))s"; break; }
  sleep 5
done
if [ "$READY" = "1" ]; then
  echo "--- PHASE C: candidate probes $(date '+%T') ---"
  $VPY $W/trial_probe2.py http://127.0.0.1:8081 $W/accept-cand-probe.json || echo "CAND_PROBE_FAIL"
  echo "cand tail64: $($VPY $W/scripts/tail64_probe.py http://127.0.0.1:8081 2>&1 | tail -1)"
  echo "--- PHASE D: needle 320K/depth120K $(date '+%T') ---"
  $VPY $W/scripts/needle_probe_swift.py http://127.0.0.1:8081 120000 320000 2>&1 | tail -3
  echo "--- PHASE E: fingerprints $(date '+%T') ---"
  echo "seeded=$(grep -c 'long prefill cache seeded' $W/accept-stack.log) desync=$(grep -c 'draft cache is not aligned' $W/accept-stack.log)"
  grep -o 'pos_accept_rate=\[[^]]*\]' $W/accept-stack.log | tail -2
  echo "errs=$(grep -cE 'FastLLM Error|Traceback' $W/accept-stack.log)"
else
  echo "CANDIDATE NOT READY"; tail -30 $W/accept-stack.log
fi
kill $TPID 2>/dev/null; sleep 10; kill -9 $TPID 2>/dev/null
j=0; while [ $j -lt 90 ]; do used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits -i 0); [ "$used" -lt 3000 ] && break; sleep 2; j=$((j+1)); done
start_prod
echo "R9B_ACCEPT_DONE $(date '+%F %T') prod=$PROD_OK" > $STATUS
cat $STATUS
echo "========= R9B ACCEPT END $(date '+%F %T') ========="
