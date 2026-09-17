#!/bin/bash
# run_window_chunk.sh — chunk 组合验证窗（2026-09-17，v2：全配置携带 NCCL_PROTO=LL128 对齐生产基座）
#   序列：W0 LL128+512×4（生产原样） | W1 LL128+2048×16【组合候选】 | W2 LL128+1024×8(short) | W3 LL128+2048×16+BUFFSIZE16M(probe)
#   生产自动恢复（trap EXIT）；急停：touch /home/ai-agent/builds/upgrade-test/CHUNKWIN_STOP
#   staging 使用生产本体代码（venv site-packages，so=70a04a15），仅 SCAN_ARGV/SCAN_ENV 单变量。
set -u
W=/home/ai-agent/builds/upgrade-test
V=/home/ai-agent/builds/fastllm-video-venv
VPY=$V/bin/python
EV=$W/wt-pooltrim/ops/evidence/chunk-window-20260917
mkdir -p $EV
exec > >(tee -a $W/chunkwin.log) 2>&1
trap 'systemctl is-active --quiet fastllm-qwen38-tp4 || sudo systemctl start fastllm-qwen38-tp4' EXIT

echo "===== CHUNK-WINDOW START $(date "+%F %T") ====="
rm -f $W/chunkwin.status $W/CHUNKWIN_STOP

echo "--- stop prod $(date "+%T") ---"
sudo systemctl stop fastllm-qwen38-tp4
for i in $(seq 1 60); do systemctl is-active --quiet fastllm-qwen38-tp4 || break; sleep 1; done
sleep 5
nvidia-smi --query-gpu=index,memory.used --format=csv,noheader

run_bench() { # $1=tag $2=mode
  local tag=$1 mode=$2
  local out=$EV/chunkwin_${tag}.json
  nvidia-smi --query-gpu=index,clocks.sm,clocks.mem,power.draw,temperature.gpu --format=csv,noheader -lms 1000 > $EV/chunkwin_clocks_${tag}.log 2>&1 &
  local SM=$!
  $VPY $W/scripts/bench_window_chunk.py http://127.0.0.1:8081 $out ${tag} ${mode} || echo "BENCH_FAIL $tag"
  kill $SM 2>/dev/null
}

run_cfg() { # $1=tag $2=SCAN_ENV $3=SCAN_ARGV $4=mode
  local tag=$1 senv=$2 sargv=$3 mode=$4
  echo "--- cfg $tag env=[$senv] argv=[$sargv] mode=$mode $(date "+%T") ---"
  cd $W
  SCAN_ENV="$senv" SCAN_ARGV="$sargv" nohup $VPY $W/scripts/scan_launch_chunk.py > $EV/stack-${tag}.log 2>&1 &
  local P=$!
  echo $P > $EV/stack-${tag}.pid
  local R=0
  for i in $(seq 1 240); do
    local code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8081/v1/models 2>/dev/null)
    if [ "$code" = "401" ] || [ "$code" = "200" ]; then R=1; echo "$tag READY http=$code after ~$((i*5))s"; break; fi
    kill -0 $P 2>/dev/null || { echo "$tag DIED — tail:"; tail -8 $EV/stack-${tag}.log; break; }
    sleep 5
  done
  if [ "$R" = 1 ]; then
    grep -a "scan_launch]" $EV/stack-${tag}.log | head -3
    run_bench "$tag" "$mode"
    grep -a "Speed:" $EV/stack-${tag}.log | tail -4
  fi
  kill $P 2>/dev/null; sleep 10; kill -9 $P 2>/dev/null
  for i in $(seq 1 60); do
    local used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits -i 0)
    [ "$used" -lt 3000 ] && break
    sleep 2
  done
  echo "$tag done $(date "+%T")" >> $W/chunkwin.status
}

while IFS='|' read -r tag senv sargv mode; do
  [ -z "${tag:-}" ] && continue
  [ -f $W/CHUNKWIN_STOP ] && { echo "CHUNKWIN_STOP detected"; break; }
  run_cfg "$tag" "${senv:-}" "${sargv:-}" "${mode:-full}"
done <<'CFGS'
W0|NCCL_PROTO=LL128||full
W1|NCCL_PROTO=LL128|--chunked_prefill_size=2048;--prefix_cache_snapshot_interval_pages=16|full
W2|NCCL_PROTO=LL128|--chunked_prefill_size=1024;--prefix_cache_snapshot_interval_pages=8|short
W3|NCCL_PROTO=LL128;NCCL_BUFFSIZE=16777216|--chunked_prefill_size=2048;--prefix_cache_snapshot_interval_pages=16|probe
CFGS

echo "--- restore prod $(date "+%T") ---"
sudo systemctl start fastllm-qwen38-tp4
RP=0
for i in $(seq 1 240); do
  code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8080/v1/models 2>/dev/null)
  if [ "$code" = "401" ] || [ "$code" = "200" ]; then RP=1; echo "PROD_READY http=$code after ~$((i*5))s"; break; fi
  sleep 5
done
sleep 20
nvidia-smi --query-gpu=index,memory.used --format=csv,noheader
$VPY $W/scripts/mmguard_smoke.py && echo SMOKE_OK || echo SMOKE_FAIL
echo "WINDOW_DONE prod=$RP $(date "+%T")" >> $W/chunkwin.status
echo "===== CHUNK-WINDOW END $(date "+%F %T") ====="
