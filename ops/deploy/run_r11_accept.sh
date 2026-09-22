#!/bin/bash
# run_r11_accept.sh — r11 验收套餐（2026-09-21）：prod 基线(同窗) + r11 候选全量 + 308K 针测 + 指纹
set -u
trap "" HUP
W=/home/ai-agent/builds/upgrade-test
V=/home/ai-agent/builds/fastllm-video-venv
VPY=$V/bin/python
LOG=$W/r11-accept.log
STATUS=$W/r11-accept.status
exec > >(tee -a "$LOG") 2>&1
echo "========= R11 ACCEPT START $(date '+%F %T') ========="
PROD_OK=0
restore_on_exit() { systemctl is-active --quiet fastllm-qwen38-tp4 || { echo "TRAP: restoring prod"; sudo systemctl start fastllm-qwen38-tp4; }; }
trap restore_on_exit EXIT
stop_prod() { echo "--- stop prod $(date '+%T') ---"; sudo systemctl stop fastllm-qwen38-tp4; for i in $(seq 1 40); do systemctl is-active --quiet fastllm-qwen38-tp4 || break; sleep 1; done; sleep 4; }
start_prod() { echo "--- restore prod $(date '+%T') ---"; sudo systemctl start fastllm-qwen38-tp4; PROD_OK=0; for i in $(seq 1 240); do code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8080/v1/models 2>/dev/null); if [ "$code" = "401" ] || [ "$code" = "200" ]; then PROD_OK=1; echo "PROD_READY ~$((i*5))s"; break; fi; sleep 5; done; echo "prod_ready=$PROD_OK"; bash $W/scripts/warmup_prod.sh 360 2>&1 | tail -1; }

echo "--- PHASE A: prod 基线（8080，同窗对照）$(date '+%T') ---"
bash $W/scripts/warmup_prod.sh 360 2>&1 | tail -1
$VPY $W/trial_probe2.py http://127.0.0.1:8080 $W/accept-r11-prod-probe.json > $W/accept-r11-prod-probe.out 2>&1 || echo "PROD_PROBE_INCOMPLETE"
pok=0; for m in f5de00c56dd1 30f8a5c9ee88 2adaf2269e77; do grep -q "$m" $W/accept-r11-prod-probe.out && pok=$((pok+1)); done
echo "prod md5_match=$pok/3"; tail -5 $W/accept-r11-prod-probe.out
echo "prod tail64: $($VPY $W/scripts/tail64_probe.py http://127.0.0.1:8080 2>&1 | tail -1)"

stop_prod
echo "--- PHASE C: r11 候选栈（8081，prod 同参 argv-r11-accept.json）$(date '+%T') ---"
ARGV_FILE=argv-r11-accept.json DFLASH_TB=force $VPY $W/fastllm_test_launch_r11.py > $W/accept-r11-stack.log 2>&1 &
TPID=$!
echo $TPID > $W/accept-r11-stack.pid
READY=0
for i in $(seq 1 72); do
  code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8081/v1/models 2>/dev/null)
  if [ "$code" = "401" ] || [ "$code" = "200" ]; then READY=1; echo "READY ~$((i*5))s"; break; fi
  kill -0 $TPID 2>/dev/null || { echo "DIED ~$((i*5))s"; break; }
  sleep 5
done
if [ "$READY" = "1" ]; then
  echo "--- gate/yarn 指纹 ---"
  grep -aE "context window limit|Yarn|yarn" $W/accept-r11-stack.log | head -4
  echo "--- quick probes $(date '+%T') ---"
  $VPY $W/trial_probe2.py http://127.0.0.1:8081 $W/accept-r11-cand-probe.json > $W/accept-r11-cand-probe.out 2>&1 || echo "CAND_PROBE_INCOMPLETE"
  cok=0; for m in f5de00c56dd1 30f8a5c9ee88 2adaf2269e77; do grep -q "$m" $W/accept-r11-cand-probe.out && cok=$((cok+1)); done
  echo "cand md5_match=$cok/3"; tail -5 $W/accept-r11-cand-probe.out
  echo "cand tail64: $($VPY $W/scripts/tail64_probe.py http://127.0.0.1:8081 2>&1 | tail -1)"
  echo "--- needle 308K $(date '+%T') ---"
  $VPY $W/scripts/needle_probe_swift.py http://127.0.0.1:8081 120000 320000 2>&1 | tail -3
  echo "--- fingerprints $(date '+%T') ---"
  echo "seeded=$(grep -c 'long prefill cache seeded' $W/accept-r11-stack.log) desync=$(grep -c 'draft cache is not aligned' $W/accept-r11-stack.log)"
  grep -o 'pos_accept_rate=\[[^]]*\]' $W/accept-r11-stack.log | tail -1
  echo "errs=$(grep -cE 'FastLLM Error|Traceback' $W/accept-r11-stack.log)"
else
  echo "CANDIDATE NOT READY"; tail -30 $W/accept-r11-stack.log
fi
kill $TPID 2>/dev/null; sleep 10; kill -9 $TPID 2>/dev/null
j=0; while [ $j -lt 90 ]; do used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits -i 0); [ "$used" -lt 3000 ] && break; sleep 2; j=$((j+1)); done
start_prod
echo "R11_ACCEPT_DONE $(date '+%F %T') prod=$PROD_OK" > $STATUS
cat $STATUS
echo "========= R11 ACCEPT END $(date '+%F %T') ========="
