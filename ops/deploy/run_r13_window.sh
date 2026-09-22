#!/bin/bash
# run_r13_window.sh — r13 冒烟窗口（2026-09-22）。生产暂让，脚本自带 trap 自动恢复。
# 四配置:
#   r13-force     : argv-swift-trial.json（dflash, 262144 ctx）→ md5 历史基线（r8–r12 恒定）3 pin
#   r13-ns        : argv-swift-trial-ns.json（无投机）→ md5
#   r13-triton    : argv-swift-trial.json + TRITON_SM75=1 → 与 force 输出差异（容差）+ triton 日志
#   r13-prodmirror: argv-swift-prod1m.json（生产镜像 1M+yarn）+ SSD 测试目录 + Triton → 端到端功能
set -u
W=/home/ai-agent/builds/upgrade-test
V=/home/ai-agent/builds/fastllm-video-venv
VPY=$V/bin/python
LOG=$W/r13-window.log
STATUS=$W/r13-window.status
exec > >(tee -a "$LOG") 2>&1
echo "========= R13 WINDOW START $(date "+%F %T") =========="
echo "testing so=$(md5sum $W/overlay-r13/ftllm/libfastllm_tools.so | cut -d" " -f1) (expect fa8a19ff44be621173c6eda75c628a27)"
PROD_OK=0
mkdir -p /home/ai-agent/prefix_ssd_r13test

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
  bash $W/scripts/warmup_prod.sh 360 2>&1 | tail -1
}
probe() {  # $1 launcher  $2 tag  $3 argv_file  $4 extra env  $5 check_baseline(1/0)
  local LN=$1 TAG=$2 AF=$3 EXTRA="${4:-}" CHECK="${5:-1}"
  echo "--- [$TAG] start stack ($AF) ${EXTRA} $(date "+%T") ---"
  if [ -n "$EXTRA" ]; then
    env ARGV_FILE="$AF" DFLASH_TB=force $EXTRA nohup $VPY $LN > $W/test-stack-$TAG.log 2>&1 &
  else
    ARGV_FILE="$AF" DFLASH_TB=force nohup $VPY $LN > $W/test-stack-$TAG.log 2>&1 &
  fi
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
    if [ "$CHECK" = "1" ]; then
      local ok=0
      for m in f5de00c56dd1 30f8a5c9ee88 2adaf2269e77; do grep -q "$m" $W/probe-$TAG.out && ok=$((ok+1)); done
      echo "[$TAG] md5_match=$ok/3"
    fi
    grep -E "\[PASS\]|\[FAIL\]" $W/probe-$TAG.out | tail -6
    echo "[$TAG] ssd_boot: $(grep -ac "Prefix SSD" $W/test-stack-$TAG.log)"
    echo "[$TAG] accept: $(grep -o "pos_accept_rate=\[[^]]*\]" $W/test-stack-$TAG.log | tail -1)"
    echo "[$TAG] errs=$(grep -cE "Traceback|CUDA error|out of memory" $W/test-stack-$TAG.log)"
    if [ "$TAG" = "r13-triton" ] || [ "$TAG" = "r13-prodmirror" ]; then
      echo "[$TAG] triton_log_lines=$(grep -icE "triton" $W/test-stack-$TAG.log)"
      grep -iE "triton" $W/test-stack-$TAG.log | head -4
      if [ -f "$W/probe-r13-force.out" ]; then
        echo "[$TAG] 与 force 输出差异（去时间/速度字段）:"
        diff <(sed "s/.*:: //" $W/probe-r13-force.out) <(sed "s/.*:: //" $W/probe-$TAG.out) | head -12
      fi
    fi
    if [ "$TAG" = "r13-prodmirror" ]; then
      echo "[$TAG] 启动关键行:"; grep -aE "context window limit|KV Cache Token limit|SM75 Triton|SSD prefix cache|TP prepared" $W/test-stack-$TAG.log | head -8
    fi
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

# 现场基线（生产 8080，停机前；与候选同窗 A/B）
echo "--- [prod-baseline] probe 8080 $(date "+%T") ---"
$VPY $W/trial_probe2.py http://127.0.0.1:8080 $W/probe-r13-prod.json > $W/probe-r13-prod.out 2>&1 || echo "[prod] PROBE_FAIL"
tail -6 $W/probe-r13-prod.out

stop_prod
probe $W/fastllm_test_launch_r13.py     r13-force      argv-swift-trial.json          "" 1
probe $W/fastllm_test_launch_r13.py     r13-ns         argv-swift-trial-ns.json       "" 1
probe $W/fastllm_test_launch_r13.py     r13-triton     argv-swift-trial.json          "TRITON_SM75=1" 0
probe $W/fastllm_test_launch_r13_ssd.py r13-prodmirror argv-swift-prod1m.json         "TRITON_SM75=1" 0
start_prod
echo "R13_WINDOW_DONE $(date "+%F %T") prod=$PROD_OK" > $STATUS
cat $STATUS
echo "========= R13 WINDOW END $(date "+%F %T") =========="
