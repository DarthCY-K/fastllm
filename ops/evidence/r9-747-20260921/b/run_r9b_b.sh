#!/bin/bash
# run_r9b_b.sh — b 阶段：#747 深验（图片前缀回归 + SSD 持久前缀跨重启 e2e；prod 同参 + SSD 开启）
set -u
trap "" HUP
W=/home/ai-agent/builds/upgrade-test
V=/home/ai-agent/builds/fastllm-video-venv
VPY=$V/bin/python
LOG=$W/r9b-b.log
STATUS=$W/r9b-b.status
exec > >(tee -a "$LOG") 2>&1
echo "========= R9B-B START $(date '+%F %T') ========="
PROD_OK=0
restore_on_exit() { systemctl is-active --quiet fastllm-qwen38-tp4 || { echo "TRAP: restoring prod"; sudo systemctl start fastllm-qwen38-tp4; }; }
trap restore_on_exit EXIT
stop_prod() { echo "--- stop prod $(date '+%T') ---"; sudo systemctl stop fastllm-qwen38-tp4; for i in $(seq 1 40); do systemctl is-active --quiet fastllm-qwen38-tp4 || break; sleep 1; done; sleep 4; }
start_prod() { echo "--- restore prod $(date '+%T') ---"; sudo systemctl start fastllm-qwen38-tp4; PROD_OK=0; for i in $(seq 1 240); do code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8080/v1/models 2>/dev/null); if [ "$code" = "401" ] || [ "$code" = "200" ]; then PROD_OK=1; echo "PROD_READY ~$((i*5))s"; break; fi; sleep 5; done; echo "prod_ready=$PROD_OK"; }
wait_gpu_free() { local j=0; while [ $j -lt 90 ]; do used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits -i 0); [ "$used" -lt 3000 ] && break; sleep 2; j=$((j+1)); done; }

mkdir -p /home/ai-agent/prefix_ssd_r9b
stop_prod

echo "--- STACK A (SSD on) $(date '+%T') ---"
ARGV_FILE=argv-r9b-accept2.json DFLASH_TB=force $VPY $W/fastllm_test_launch_r9b_ssd.py > $W/b-stackA.log 2>&1 &
APID=$!
echo $APID > $W/b-stackA.pid
READY=0
for i in $(seq 1 72); do
  code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8081/v1/models 2>/dev/null)
  if [ "$code" = "401" ] || [ "$code" = "200" ]; then READY=1; echo "A READY ~$((i*5))s"; break; fi
  kill -0 $APID 2>/dev/null || { echo "A DIED ~$((i*5))s"; break; }
  sleep 5
done
if [ "$READY" = "1" ]; then
  echo "--- SSD boot lines ---"
  grep -aE "Prefix SSD" $W/b-stackA.log | head -8
  echo "--- MM regression probe $(date '+%T') ---"
  $VPY $W/scripts/mmcache_probe_8081.py 2>&1 | tail -10
  echo "--- SSD text run1 (cold) $(date '+%T') ---"
  $VPY $W/scripts/ssd_prefix_probe.py http://127.0.0.1:8081 run1-cold 2>&1 | tail -2
  echo "--- SSD text run2 (warm same proc) $(date '+%T') ---"
  $VPY $W/scripts/ssd_prefix_probe.py http://127.0.0.1:8081 run2-warm 2>&1 | tail -2
  echo "--- wait committed (<=120s) ---"
  C=0
  for i in $(seq 1 24); do C=$(grep -ac "Prefix SSD. committed" $W/b-stackA.log); [ "$C" -ge 1 ] && break; sleep 5; done
  echo "committed_count=$C"
  grep -a "Prefix SSD. committed" $W/b-stackA.log | tail -2
else
  echo "STACK A NOT READY"; tail -30 $W/b-stackA.log
fi
echo "--- stop A (graceful TERM) $(date '+%T') ---"
kill -TERM $APID 2>/dev/null
for i in $(seq 1 50); do kill -0 $APID 2>/dev/null || break; sleep 2; done
kill -9 $APID 2>/dev/null
wait_gpu_free

echo "--- STACK B (SSD on, restart) $(date '+%T') ---"
ARGV_FILE=argv-r9b-accept2.json DFLASH_TB=force $VPY $W/fastllm_test_launch_r9b_ssd.py > $W/b-stackB.log 2>&1 &
BPID=$!
echo $BPID > $W/b-stackB.pid
READY=0
for i in $(seq 1 72); do
  code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8081/v1/models 2>/dev/null)
  if [ "$code" = "401" ] || [ "$code" = "200" ]; then READY=1; echo "B READY ~$((i*5))s"; break; fi
  kill -0 $BPID 2>/dev/null || { echo "B DIED ~$((i*5))s"; break; }
  sleep 5
done
if [ "$READY" = "1" ]; then
  echo "--- SSD text run3 (restart; expect restored) $(date '+%T') ---"
  $VPY $W/scripts/ssd_prefix_probe.py http://127.0.0.1:8081 run3-restart 2>&1 | tail -2
  echo "--- restored/loaded lines ---"
  grep -aE "Prefix SSD. (restored|loaded)" $W/b-stackB.log | tail -4
  echo "--- errs A=$(grep -acE 'FastLLM Error|Traceback' $W/b-stackA.log) B=$(grep -acE 'FastLLM Error|Traceback' $W/b-stackB.log) ---"
else
  echo "STACK B NOT READY"; tail -30 $W/b-stackB.log
fi
kill -TERM $BPID 2>/dev/null
for i in $(seq 1 50); do kill -0 $BPID 2>/dev/null || break; sleep 2; done
kill -9 $BPID 2>/dev/null
wait_gpu_free
start_prod
echo "R9B_B_DONE $(date '+%F %T') prod=$PROD_OK" > $STATUS
cat $STATUS
echo "========= R9B-B END $(date '+%F %T') ========="
