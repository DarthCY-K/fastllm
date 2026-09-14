#!/bin/bash
# AB5 rigorous run: A_pre(prod) -> B(r2 default) -> C(r2 + snap interval 16) -> A_post(prod)
# All phases use the same ab5_rigorous.py suite. Prod is restored even on abort (EXIT trap).
set -u
W=/home/ai-agent/builds/upgrade-test
V=/home/ai-agent/builds/fastllm-video-venv
VPY=$V/bin/python
PLOG=/home/ai-agent/fastllm-video-repro/results/server-prod.service.log
S=$W/ab5.status
exec > >(tee -a $W/ab5.log) 2>&1
trap 'systemctl is-active --quiet fastllm-qwen38-tp4 || sudo systemctl start fastllm-qwen38-tp4' EXIT

echo "===== AB5 START $(date '+%F %T') ====="
rm -f $W/ab5.status $W/ab5_A_pre.json $W/ab5_B.json $W/ab5_C.json $W/ab5_A_post.json $W/ab5_offsets.txt $W/.ready_b $W/.ready_c

bench() { $VPY $W/scripts/ab5_rigorous.py "$1" "$2" "$3" || echo "BENCH_FAIL $3"; }

plog_off() { stat -c "$1 %s" $PLOG >> $W/ab5_offsets.txt; echo "stored $1 at $(stat -c %s $PLOG)"; }

echo "--- PHASE A_pre: prod live $(date '+%T') ---"
plog_off PLOG_OFFSET_A_PRE
bench http://127.0.0.1:8080 $W/ab5_A_pre.json A_pre
plog_off PLOG_OFFSET_A_PRE_END

echo "--- PHASE stop prod $(date '+%T') ---"
sudo systemctl stop fastllm-qwen38-tp4
for i in $(seq 1 40); do systemctl is-active --quiet fastllm-qwen38-tp4 || break; sleep 1; done
sleep 5
nvidia-smi --query-gpu=index,memory.used --format=csv,noheader

start_stack() { # $1=launcher $2=log $3=tag -> writes 1/0 to $W/.ready_$3
  cd $W
  nohup $VPY "$1" > "$2" 2>&1 &
  local P=$!
  echo $P > $W/stack-${3,,}.pid
  for i in $(seq 1 240); do
    local code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8081/v1/models 2>/dev/null)
    if [ "$code" = "401" ] || [ "$code" = "200" ]; then echo "${3}_READY http=$code after ~$((i*5))s"; echo 1 > $W/.ready_$3; return 0; fi
    kill -0 $P 2>/dev/null || { echo "${3}_DIED"; echo 0 > $W/.ready_$3; return 0; }
    sleep 5
  done
  echo "${3}_TIMEOUT"; echo 0 > $W/.ready_$3
}
stop_stack() { # $1=tag
  local P=$(cat $W/stack-${1,,}.pid 2>/dev/null)
  [ -n "$P" ] && kill $P 2>/dev/null
  sleep 10
  [ -n "$P" ] && kill -9 $P 2>/dev/null
  for i in $(seq 1 40); do
    local used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits -i 0)
    [ "$used" -lt 3000 ] && break
    sleep 2
  done
  nvidia-smi --query-gpu=index,memory.used --format=csv,noheader
}

echo "--- PHASE B: r2 default chunking $(date '+%T') ---"
start_stack $W/fastllm_test_launch_r2.py $W/stack-b.log B
if [ "$(cat $W/.ready_B)" = "1" ]; then bench http://127.0.0.1:8081 $W/ab5_B.json B; else echo B_NOT_READY; fi
stop_stack B

echo "--- PHASE C: r2 + snapshot interval 16 pages $(date '+%T') ---"
start_stack $W/fastllm_test_launch_r2_snap16.py $W/stack-c.log C
if [ "$(cat $W/.ready_C)" = "1" ]; then bench http://127.0.0.1:8081 $W/ab5_C.json C; else echo C_NOT_READY; fi
stop_stack C

echo "--- PHASE restore prod $(date '+%T') ---"
sudo systemctl start fastllm-qwen38-tp4
RP=0
for i in $(seq 1 180); do
  code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8080/v1/models 2>/dev/null)
  if [ "$code" = "401" ] || [ "$code" = "200" ]; then RP=1; echo "PROD_READY http=$code after ~$((i*5))s"; break; fi
  sleep 5
done
plog_off PLOG_OFFSET_A_POST
bench http://127.0.0.1:8080 $W/ab5_A_post.json A_post
plog_off PLOG_OFFSET_A_POST_END

echo "AB5_DONE prod=$RP" > $S
echo "===== AB5 END $(date '+%F %T') ====="
