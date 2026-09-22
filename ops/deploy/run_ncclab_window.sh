#!/bin/bash
# run_ncclab_window.sh — NCCL 会合自旋 A/B（2026-09-23）
# 臂顺序（单变量，交错控制漂移）：P(生产 so, 无旋钮) → A(spin=2048) → B(spin=0) → A → B
# 每臂：起栈(8081, argv-swift-trial.json, DFLASH_TB=force) → 5×512tok 解码 + 20×短请求 + 探针 md5 → 杀栈
# 收尾：trap 恢复生产 + 暖机
set -u
trap "" HUP
W=/home/ai-agent/builds/upgrade-test
VPY=/home/ai-agent/builds/fastllm-video-venv/bin/python
LOG=$W/ncclab-window.log
STATUS=$W/ncclab-window.status
exec > >(tee -a "$LOG") 2>&1
echo "========= NCCLAB WINDOW START $(date '+%F %T') ========="
echo "prod so=$(md5sum $W/overlay-r13/ftllm/libfastllm_tools.so | cut -c1-32)  knob so=$(md5sum $W/overlay-r13-ncclab/ftllm/libfastllm_tools.so | cut -c1-32)"
PROD_OK=0
restore_on_exit() { systemctl is-active --quiet fastllm-qwen38-tp4 || { echo "TRAP: restoring prod"; sudo systemctl start fastllm-qwen38-tp4; }; }
trap restore_on_exit EXIT
stop_prod() { echo "--- stop prod $(date '+%T') ---"; sudo systemctl stop fastllm-qwen38-tp4; for i in $(seq 1 40); do systemctl is-active --quiet fastllm-qwen38-tp4 || break; sleep 1; done; sleep 4; }
start_prod() { echo "--- restore prod $(date '+%T') ---"; sudo systemctl start fastllm-qwen38-tp4; PROD_OK=0
  for i in $(seq 1 240); do code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8080/v1/models 2>/dev/null)
    if [ "$code" = "401" ] || [ "$code" = "200" ]; then PROD_OK=1; echo "PROD_READY ~$((i*5))s"; break; fi; sleep 5; done
  bash $W/scripts/warmup_prod.sh 240 2>&1 | tail -1; }
wait_ready() { local TPID=$1 READY=0 i code
  for i in $(seq 1 72); do
    code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8081/v1/models 2>/dev/null)
    if [ "$code" = "401" ] || [ "$code" = "200" ]; then READY=1; echo "READY ~$((i*5))s" >&2; break; fi
    kill -0 $TPID 2>/dev/null || { echo "DIED ~$((i*5))s" >&2; break; }; sleep 5; done
  echo $READY; }
kill_stack() { local TPID=$1 j used
  kill $TPID 2>/dev/null; sleep 10; kill -9 $TPID 2>/dev/null
  j=0; while [ $j -lt 120 ]; do used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits -i 0); [ "$used" -lt 3000 ] && break; sleep 2; j=$((j+1)); done; }

run_arm() {
  local LABEL=$1 OVERLAY=$2 SPIN=$3
  echo "--- ARM $LABEL  overlay=$OVERLAY spin=${SPIN:-unset} $(date '+%T') ---"
  ARGV_FILE=argv-swift-trial.json DFLASH_TB=force OVERLAY=$OVERLAY NCCL_SPIN=$SPIN \
    $VPY $W/fastllm_test_launch_r13ncclab.py > $W/ncclab-$LABEL-stack.log 2>&1 &
  local TPID=$!; echo $TPID > $W/ncclab-$LABEL-stack.pid
  local R=$(wait_ready $TPID)
  if [ "$R" != "1" ]; then echo "ARM $LABEL NOT READY"; tail -20 $W/ncclab-$LABEL-stack.log; return 1; fi
  echo "ARM $LABEL child_env: $(SPID=$(pgrep -f 'ftllm.cli server' | head -1); tr '\0' '\n' < /proc/$SPID/environ 2>/dev/null | grep -o '^FASTLLM_NCCL_RENDEZVOUS_SPIN=.*' || echo '(未注入)')"
  $VPY $W/ncclab_bench.py http://127.0.0.1:8081 $LABEL 2>&1 | tee $W/ncclab-$LABEL-bench.out | tail -8
  $VPY $W/trial_probe2.py http://127.0.0.1:8081 $W/ncclab-$LABEL-probe.json > $W/ncclab-$LABEL-probe.out 2>&1
  local n=0; for m in f5de00c56dd1 30f8a5c9ee88 2adaf2269e77; do grep -q "$m" $W/ncclab-$LABEL-probe.out && n=$((n+1)); done
  echo "ARM $LABEL pins=$n/3 errs=$(grep -cE 'FastLLM Error|Traceback' $W/ncclab-$LABEL-stack.log)"
  kill_stack $TPID
}

stop_prod
run_arm P  overlay-r13          ""
run_arm A1 overlay-r13-ncclab   2048
run_arm B1 overlay-r13-ncclab   0
run_arm A2 overlay-r13-ncclab   2048
run_arm B2 overlay-r13-ncclab   0
start_prod

echo "--- 汇总 ---"
for L in P A1 B1 A2 B2; do echo "$L: $(grep -a BENCH_JSON $W/ncclab-$L-bench.out | tail -1)"; done
echo "NCCLAB_DONE $(date '+%F %T') prod=$PROD_OK" > $STATUS
echo "========= NCCLAB WINDOW END $(date '+%F %T') ========="
