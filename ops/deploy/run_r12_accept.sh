#!/bin/bash
# run_r12_accept.sh — r12 验收套餐（2026-09-22）
# PHASE A: prod 基线(8080, 同窗) | PHASE C: r12 候选(8081, 生产同参) | PHASE D: r12-triton(同参+TRITON_SM75=1, 长 prefill A/B + 编译服务自拉起验证)
set -u
trap "" HUP
W=/home/ai-agent/builds/upgrade-test
V=/home/ai-agent/builds/fastllm-video-venv
VPY=$V/bin/python
LOG=$W/r12-accept.log
STATUS=$W/r12-accept.status
exec > >(tee -a "$LOG") 2>&1
echo "========= R12 ACCEPT START $(date '+%F %T') ========="
echo "candidate so=$(md5sum $W/overlay-r12/ftllm/libfastllm_tools.so | cut -d' ' -f1)"
PROD_OK=0
restore_on_exit() { systemctl is-active --quiet fastllm-qwen38-tp4 || { echo "TRAP: restoring prod"; sudo systemctl start fastllm-qwen38-tp4; }; }
trap restore_on_exit EXIT
stop_prod() { echo "--- stop prod $(date '+%T') ---"; sudo systemctl stop fastllm-qwen38-tp4; for i in $(seq 1 40); do systemctl is-active --quiet fastllm-qwen38-tp4 || break; sleep 1; done; sleep 4; }
start_prod() { echo "--- restore prod $(date '+%T') ---"; sudo systemctl start fastllm-qwen38-tp4; PROD_OK=0; for i in $(seq 1 240); do code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8080/v1/models 2>/dev/null); if [ "$code" = "401" ] || [ "$code" = "200" ]; then PROD_OK=1; echo "PROD_READY ~$((i*5))s"; break; fi; sleep 5; done; echo "prod_ready=$PROD_OK"; bash $W/scripts/warmup_prod.sh 360 2>&1 | tail -1; }

wait_ready() {  # $1 pid -> stdout 只输出 0/1；进度走 stderr
  local TPID=$1 READY=0 i code
  for i in $(seq 1 72); do
    code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8081/v1/models 2>/dev/null)
    if [ "$code" = "401" ] || [ "$code" = "200" ]; then READY=1; echo "READY ~$((i*5))s" >&2; break; fi
    kill -0 $TPID 2>/dev/null || { echo "DIED ~$((i*5))s" >&2; break; }
    sleep 5
  done
  echo $READY
}
kill_stack() {  # $1 pid
  local TPID=$1 j used
  kill $TPID 2>/dev/null; sleep 10; kill -9 $TPID 2>/dev/null
  j=0; while [ $j -lt 120 ]; do used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits -i 0); [ "$used" -lt 3000 ] && break; sleep 2; j=$((j+1)); done
  nvidia-smi --query-gpu=index,memory.used --format=csv,noheader | tr "\n" " "; echo
}

echo "--- PHASE A: prod 基线（8080，同窗对照）$(date '+%T') ---"
bash $W/scripts/warmup_prod.sh 360 2>&1 | tail -1
$VPY $W/trial_probe2.py http://127.0.0.1:8080 $W/accept-r12-prod-probe.json > $W/accept-r12-prod-probe.out 2>&1 || echo "PROD_PROBE_INCOMPLETE"
pok=0; for m in f5de00c56dd1 30f8a5c9ee88 2adaf2269e77; do grep -q "$m" $W/accept-r12-prod-probe.out && pok=$((pok+1)); done
echo "prod md5_match=$pok/3"; tail -5 $W/accept-r12-prod-probe.out
echo "prod tail64: $($VPY $W/scripts/tail64_probe.py http://127.0.0.1:8080 2>&1 | tail -1)"

stop_prod
echo "--- PHASE C: r12 候选（8081，prod 同参）$(date '+%T') ---"
ARGV_FILE=argv-r12-accept.json DFLASH_TB=force $VPY $W/fastllm_test_launch_r12.py > $W/accept-r12-stack.log 2>&1 &
TPID=$!; echo $TPID > $W/accept-r12-stack.pid
R=$(wait_ready $TPID)
if [ "$R" = "1" ]; then
  echo "--- gate/yarn 指纹 ---"; grep -aE "context window limit|Yarn|yarn" $W/accept-r12-stack.log | head -4
  $VPY $W/trial_probe2.py http://127.0.0.1:8081 $W/accept-r12-cand-probe.json > $W/accept-r12-cand-probe.out 2>&1 || echo "CAND_PROBE_INCOMPLETE"
  cok=0; for m in f5de00c56dd1 30f8a5c9ee88 2adaf2269e77; do grep -q "$m" $W/accept-r12-cand-probe.out && cok=$((cok+1)); done
  echo "cand md5_match=$cok/3"; tail -5 $W/accept-r12-cand-probe.out
  echo "cand tail64: $($VPY $W/scripts/tail64_probe.py http://127.0.0.1:8081 2>&1 | tail -1)"
  echo "--- needle 308K (PHASE C) $(date '+%T') ---"
  $VPY $W/scripts/needle_probe_swift.py http://127.0.0.1:8081 120000 320000 2>&1 | tail -3
  echo "--- fingerprints $(date '+%T') ---"
  echo "seeded=$(grep -c 'long prefill cache seeded' $W/accept-r12-stack.log) desync=$(grep -c 'draft cache is not aligned' $W/accept-r12-stack.log)"
  grep -o 'pos_accept_rate=\[[^]]*\]' $W/accept-r12-stack.log | tail -1
  echo "errs=$(grep -cE 'FastLLM Error|Traceback' $W/accept-r12-stack.log)"
else
  echo "CANDIDATE NOT READY"; tail -30 $W/accept-r12-stack.log
fi
kill_stack $TPID

echo "--- PHASE D: r12-triton（同参 + TRITON_SM75=1；先停编译服务验证引擎自拉起）$(date '+%T') ---"
if [ -f $W/triton-sm75-server.pid ]; then kill $(cat $W/triton-sm75-server.pid) 2>/dev/null; sleep 2; fi
pkill -f "fastllm_triton_server.py --host 127.0.0.1 --port 48989" 2>/dev/null; sleep 1
if ss -ltn 2>/dev/null | grep -q 48989; then echo "D: WARN :48989 仍在监听"; else echo "D: :48989 已停（等待引擎自拉起）"; fi
mv /tmp/fastllm_triton_server.log /tmp/fastllm_triton_server.log.preD 2>/dev/null
ARGV_FILE=argv-r12-accept.json DFLASH_TB=force TRITON_SM75=1 $VPY $W/fastllm_test_launch_r12.py > $W/accept-r12-triton-stack.log 2>&1 &
TPID=$!; echo $TPID > $W/accept-r12-triton-stack.pid
R=$(wait_ready $TPID)
if [ "$R" = "1" ]; then
  $VPY $W/trial_probe2.py http://127.0.0.1:8081 $W/accept-r12-triton-probe.json > $W/accept-r12-triton-probe.out 2>&1 || echo "TRITON_PROBE_INCOMPLETE"
  tok=0; for m in f5de00c56dd1 30f8a5c9ee88 2adaf2269e77; do grep -q "$m" $W/accept-r12-triton-probe.out && tok=$((tok+1)); done
  echo "triton md5_match=$tok/3"; tail -5 $W/accept-r12-triton-probe.out
  echo "--- spawn 验证：编译服务进程 ---"
  pgrep -af "fastllm_triton_server" | head -4 || echo "(无 server 进程)"
  echo "--- 引擎 spawn 日志 /tmp/fastllm_triton_server.log ---"
  head -3 /tmp/fastllm_triton_server.log 2>/dev/null || echo "(日志未生成 → 引擎未 spawn)"
  echo "triton tail64: $($VPY $W/scripts/tail64_probe.py http://127.0.0.1:8081 2>&1 | tail -1)"
  echo "--- needle 308K (PHASE D) $(date '+%T') ---"
  $VPY $W/scripts/needle_probe_swift.py http://127.0.0.1:8081 120000 320000 2>&1 | tail -3
  echo "--- D 指纹 ---"
  echo "errs=$(grep -cE 'FastLLM Error|Traceback' $W/accept-r12-triton-stack.log)"
  echo "triton_log_lines=$(grep -aicE 'triton' $W/accept-r12-triton-stack.log)"
else
  echo "TRITON STACK NOT READY"; tail -30 $W/accept-r12-triton-stack.log
fi
kill_stack $TPID

start_prod
echo "R12_ACCEPT_DONE $(date '+%F %T') prod=$PROD_OK" > $STATUS
cat $STATUS
echo "========= R12 ACCEPT END $(date '+%F %T') ========="
