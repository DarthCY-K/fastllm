#!/bin/bash
# AB6: r2-default stabilization round (single stack, no A phases).
set -u
W=/home/ai-agent/builds/upgrade-test
V=/home/ai-agent/builds/fastllm-video-venv
VPY=$V/bin/python
S=$W/ab6.status
exec > >(tee -a $W/ab6.log) 2>&1
trap 'systemctl is-active --quiet fastllm-qwen38-tp4 || sudo systemctl start fastllm-qwen38-tp4' EXIT

echo "===== AB6 START $(date '+%F %T') ====="
rm -f $W/ab6.status $W/ab6_B.json $W/.ready_b2

echo "--- stop prod $(date '+%T') ---"
sudo systemctl stop fastllm-qwen38-tp4
for i in $(seq 1 40); do systemctl is-active --quiet fastllm-qwen38-tp4 || break; sleep 1; done
sleep 5
nvidia-smi --query-gpu=index,memory.used --format=csv,noheader

echo "--- B2 stack: r2 default $(date '+%T') ---"
cd $W
nohup $VPY $W/fastllm_test_launch_r2.py > $W/stack-b2.log 2>&1 &
P=$!
echo $P > $W/stack-b2.pid
READY=0
for i in $(seq 1 240); do
  code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8081/v1/models 2>/dev/null)
  if [ "$code" = "401" ] || [ "$code" = "200" ]; then READY=1; echo "B2_READY http=$code after ~$((i*5))s"; break; fi
  kill -0 $P 2>/dev/null || { echo B2_DIED; break; }
  sleep 5
done
if [ "$READY" = 1 ]; then
  $VPY $W/scripts/ab6_rigorous.py http://127.0.0.1:8081 $W/ab6_B.json || echo BENCH_FAIL
fi
kill $P 2>/dev/null; sleep 10; kill -9 $P 2>/dev/null
for i in $(seq 1 40); do used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits -i 0); [ "$used" -lt 3000 ] && break; sleep 2; done
nvidia-smi --query-gpu=index,memory.used --format=csv,noheader

echo "--- restore prod $(date '+%T') ---"
sudo systemctl start fastllm-qwen38-tp4
RP=0
for i in $(seq 1 180); do
  code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8080/v1/models 2>/dev/null)
  if [ "$code" = "401" ] || [ "$code" = "200" ]; then RP=1; echo "PROD_READY http=$code after ~$((i*5))s"; break; fi
  sleep 5
done
echo "AB6_DONE ready=$READY prod=$RP" > $S
echo "===== AB6 END $(date '+%F %T') ====="
