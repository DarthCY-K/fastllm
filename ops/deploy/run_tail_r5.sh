#!/bin/bash
# run_tail_r5.sh — r5 staging window 2: converged DFlash tail-chunk regression (probe v2).
set -u
W=/home/ai-agent/builds/upgrade-test
V=/home/ai-agent/builds/fastllm-video-venv
VPY=$V/bin/python
LOG=$W/test-stack-r5-tail2.log
PRODLOG=/home/ai-agent/fastllm-video-repro/results/server-prod.service.log
SMOKE=$W/smoke-r5-tail2.log
STATUS=$W/smoke-tail2-r5.status

exec > >(tee -a "$SMOKE") 2>&1
echo "================ TAIL2 WINDOW START $(date '+%F %T') ================"

echo "--- PHASE0 prod baseline (8080) ---"
P0=$(wc -l < $PRODLOG 2>/dev/null || echo 0)
$VPY $W/r5_tail_probe2.py http://127.0.0.1:8080 $W/r5-tail2-prod.json PROD_TAIL2 || echo BASELINE_INCOMPLETE
echo "-- prod seeded lines since PHASE0 --"
tail -n +$((P0+1)) $PRODLOG | grep -o 'long prefill cache seeded: tokens=[0-9]*, chunk=[0-9]*' | tail -12
echo "-- prod desync since PHASE0: $(tail -n +$((P0+1)) $PRODLOG | grep -c 'draft cache is not aligned')"

echo "--- PHASE1 stop prod $(date '+%T') ---"
sudo systemctl stop fastllm-qwen38-tp4
for i in $(seq 1 40); do systemctl is-active --quiet fastllm-qwen38-tp4 || break; sleep 1; done
sleep 4

echo "--- PHASE2 start test stack $(date '+%T') ---"
cd $W
nohup $VPY $W/fastllm_test_launch_r5.py > $LOG 2>&1 &
TPID=$!
echo $TPID > $W/test-r5-tail2.pid

echo "--- PHASE3 wait ready ---"
READY=0
for i in $(seq 1 240); do
  code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8081/v1/models 2>/dev/null)
  if [ "$code" = "401" ] || [ "$code" = "200" ]; then READY=1; echo "READY http=$code after ~$((i*5))s"; break; fi
  if ! kill -0 $TPID 2>/dev/null; then echo TEST_PROCESS_DIED; break; fi
  sleep 5
done
[ "$READY" = "0" ] && { echo NOT_READY; tail -40 $LOG; }

if [ "$READY" = "1" ]; then
  echo "--- PHASE4 tail probe v2 (8081) $(date '+%T') ---"
  $VPY $W/r5_tail_probe2.py http://127.0.0.1:8081 $W/r5-tail2-test.json R5_TAIL2 || echo TAIL_PROBE_INCOMPLETE
  echo "-- seeded / desync / acceptance (test stack) --"
  printf "seeded=%s desync=%s\n" "$(grep -c 'long prefill cache seeded' $LOG)" "$(grep -c 'draft cache is not aligned' $LOG)"
  grep -o 'long prefill cache seeded: tokens=[0-9]*, chunk=[0-9]*' $LOG | tail -12
  grep -o 'pos_accept_rate=\[[^]]*\]' $LOG | tail -3
  echo "-- 异常扫描 --"; grep -nE "Traceback|CUDA error|out of memory" $LOG | head -5 || true
  echo "-- GPU --"; nvidia-smi --query-gpu=index,memory.used,temperature.gpu --format=csv,noheader
  cp $LOG $W/artifacts-tail2-test.log 2>/dev/null || true
fi

echo "--- PHASE5 stop test $(date '+%T') ---"
kill $TPID 2>/dev/null; sleep 10; kill -9 $TPID 2>/dev/null
for i in $(seq 1 30); do kill -0 $TPID 2>/dev/null || break; sleep 1; done
for i in $(seq 1 45); do
  used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits -i 0)
  [ "$used" -lt 3000 ] && break
  sleep 2
done
nvidia-smi --query-gpu=index,memory.used --format=csv,noheader

echo "--- PHASE6 restore prod $(date '+%T') ---"
sudo systemctl start fastllm-qwen38-tp4
RP=0
for i in $(seq 1 180); do
  code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8080/v1/models 2>/dev/null)
  if [ "$code" = "401" ] || [ "$code" = "200" ]; then RP=1; echo "PROD_READY http=$code after ~$((i*5))s"; break; fi
  sleep 5
done
echo "TAIL2_WINDOW_DONE ready=$READY prod=$RP" > $STATUS
echo "================ TAIL2 WINDOW END $(date '+%F %T') ================"
