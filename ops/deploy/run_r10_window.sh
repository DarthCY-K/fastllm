#!/bin/bash
# run_r10_window.sh — r10 冒烟窗口（2026-09-21）。生产暂让，脚本自动恢复。
# 探针: r10-force（dflash argv） / r10-ns（无投机 argv） / r10-ssd（现产同配+SSD env）
# md5 对照 r8 基线: f5de00c5 / 30f8a5c9ee88 / 2adaf2269e77
set -u
W=/home/ai-agent/builds/upgrade-test
V=/home/ai-agent/builds/fastllm-video-venv
VPY=$V/bin/python
LOG=$W/r10-window.log
STATUS=$W/r10-window.status
exec > >(tee -a "$LOG") 2>&1
echo "========= R10 WINDOW START $(date "+%F %T") ========="
PROD_OK=0
mkdir -p /home/ai-agent/prefix_ssd_r10test

restore_on_exit() {
  if ! systemctl is-active --quiet fastllm-qwen38-tp4; then
    echo "--- TRAP: restoring prod $(date "+%T") ---"
    sudo systemctl start fastllm-qwen38-tp4
  fi
}
trap restore_on_exit EXIT

stop_prod() {
  echo "--- stop prod $(date "+%T") ---"
  sudo systemctl stop fastllm-qwen38-tp4
  for i in $(seq 1 40); do systemctl is-active --quiet fastllm-qwen38-tp4 || break; sleep 1; done
  sleep 4
}
start_prod() {
  echo "--- restore prod $(date "+%T") ---"
  sudo systemctl start fastllm-qwen38-tp4
  PROD_OK=0
  for i in $(seq 1 240); do
    code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8080/v1/models 2>/dev/null)
    if [ "$code" = "401" ] || [ "$code" = "200" ]; then PROD_OK=1; echo "PROD_READY after ~$((i*5))s"; break; fi
    sleep 5
  done
  echo "prod_ready=$PROD_OK"
}
probe() {  # $1 launcher, $2 tag, $3 argv_file
  local LN=$1 TAG=$2 AF=$3
  echo "--- [$TAG] start stack ($AF) $(date "+%T") ---"
  ARGV_FILE=$AF DFLASH_TB=force nohup $VPY $LN > $W/test-stack-$TAG.log 2>&1 &
  local TPID=$!
  echo $TPID > $W/test-$TAG.pid
  local READY=0
  for i in $(seq 1 72); do
    local code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8081/v1/models 2>/dev/null)
    if [ "$code" = "401" ] || [ "$code" = "200" ]; then READY=1; echo "[$TAG] READY http=$code ~$((i*5))s"; break; fi
    kill -0 $TPID 2>/dev/null || { echo "[$TAG] DIED ~$((i*5))s"; break; }
    sleep 5
  done
  if [ "$READY" = "1" ]; then
    $VPY $W/trial_probe2.py http://127.0.0.1:8081 $W/probe-$TAG.json > $W/probe-$TAG.out 2>&1 || echo "[$TAG] PROBE_FAIL"
    local ok=0
    for m in f5de00c56dd1 30f8a5c9ee88 2adaf2269e77; do grep -q "$m" $W/probe-$TAG.out && ok=$((ok+1)); done
    echo "[$TAG] md5_match=$ok/3"
    tail -6 $W/probe-$TAG.out
    echo "[$TAG] ssd_boot: $(grep -ac 'Prefix SSD' $W/test-stack-$TAG.log)"
    echo "[$TAG] accept: $(grep -o "pos_accept_rate=\[[^]]*\]" $W/test-stack-$TAG.log | tail -1)"
    echo "[$TAG] errs=$(grep -cE "Traceback|CUDA error|out of memory" $W/test-stack-$TAG.log)"
  else
    echo "[$TAG] tail:"; tail -20 $W/test-stack-$TAG.log
  fi
  kill $TPID 2>/dev/null; sleep 8; kill -9 $TPID 2>/dev/null
  local j=0
  while [ $j -lt 60 ]; do
    local used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits -i 0)
    [ "$used" -lt 3000 ] && break
    sleep 2; j=$((j+1))
  done
  nvidia-smi --query-gpu=index,memory.used --format=csv,noheader | tr "\n" " "; echo
}

stop_prod
probe $W/fastllm_test_launch_r10.py     r10-force argv-swift-trial.json
probe $W/fastllm_test_launch_r10_ns.py  r10-ns    argv-swift-trial-ns.json
probe $W/fastllm_test_launch_r10_ssd.py r10-ssd   argv-swift-trial.json
start_prod
echo "R10_WINDOW_DONE $(date "+%F %T") prod=$PROD_OK" > $STATUS
cat $STATUS
echo "========= R10 WINDOW END $(date "+%F %T") ========="
