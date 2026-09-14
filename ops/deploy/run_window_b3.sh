#!/bin/bash
# run_window_b3.sh — 破解交替混淆的连续重复窗
# 序列：LL128×3 连跑 | LL128+DEBUG | base+DEBUG | base | chunk2048×2
# 目的：(1) LL128 预填增益 vs 整栈状态交替；(2) W1r 慢 decode 是否与 NCCL_DEBUG 相关；
#       (3) 基线所选 algo/proto 取证；(4) chunk2048/i16 复测。
set -u
W=/home/ai-agent/builds/upgrade-test
V=/home/ai-agent/builds/fastllm-video-venv
VPY=$V/bin/python
exec > >(tee -a $W/windowb3.log) 2>&1
trap 'systemctl is-active --quiet fastllm-qwen38-tp4 || sudo systemctl start fastllm-qwen38-tp4' EXIT

echo "===== WINDOW-B3 START $(date "+%F %T") ====="
rm -f $W/windowb3.status $W/WINDOWB3_STOP

echo "--- stop prod $(date "+%T") ---"
sudo systemctl stop fastllm-qwen38-tp4
for i in $(seq 1 40); do systemctl is-active --quiet fastllm-qwen38-tp4 || break; sleep 1; done
sleep 5
nvidia-smi --query-gpu=index,memory.used --format=csv,noheader

run_bench() { # $1=tag
  local tag=$1
  local out=$W/wb3_${tag}.json
  nvidia-smi --query-gpu=index,clocks.sm,clocks.mem,power.draw,temperature.gpu --format=csv,noheader -lms 1000 > $W/wb3_clocks_${tag}.log 2>&1 &
  local SM=$!
  $VPY $W/scripts/scan_bench2b.py http://127.0.0.1:8081 $out ${tag} || echo "BENCH_FAIL $tag"
  kill $SM 2>/dev/null
}

run_cfg() { # $1=tag $2=SCAN_ENV $3=SCAN_ARGV
  local tag=$1 senv=$2 sargv=$3
  echo "--- cfg $tag env=[$senv] argv=[$sargv] $(date "+%T") ---"
  cd $W
  SCAN_ENV="$senv" SCAN_ARGV="$sargv" nohup $VPY $W/scripts/scan_launch.py > $W/stack-wb3-$tag.log 2>&1 &
  local P=$!
  echo $P > $W/stack-wb3-$tag.pid
  local R=0
  for i in $(seq 1 240); do
    local code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8081/v1/models 2>/dev/null)
    if [ "$code" = "401" ] || [ "$code" = "200" ]; then R=1; echo "$tag READY http=$code after ~$((i*5))s"; break; fi
    kill -0 $P 2>/dev/null || { echo "$tag DIED — tail:"; tail -8 $W/stack-wb3-$tag.log; break; }
    sleep 5
  done
  if [ "$R" = 1 ]; then
    grep -a "scan_launch]" $W/stack-wb3-$tag.log | head -3
    grep -aiE "Best tuning|AllReduce: .* -> Algo|Connected all (rings|trees)|NCCL Initialized" $W/stack-wb3-$tag.log | head -12
    run_bench "$tag"
    grep -a "Speed:" $W/stack-wb3-$tag.log | tail -4
  fi
  kill $P 2>/dev/null; sleep 10; kill -9 $P 2>/dev/null
  for i in $(seq 1 40); do
    local used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits -i 0)
    [ "$used" -lt 3000 ] && break
    sleep 2
  done
  echo "$tag done $(date "+%T")" >> $W/windowb3.status
}

while IFS='|' read -r tag senv sargv; do
  [ -z "${tag:-}" ] && continue
  [ -f $W/WINDOWB3_STOP ] && { echo "WINDOWB3_STOP detected"; break; }
  run_cfg "$tag" "${senv:-}" "${sargv:-}"
done <<'CFGS'
W1A|NCCL_PROTO=LL128|
W1B|NCCL_PROTO=LL128|
W1C|NCCL_PROTO=LL128|
W1D|NCCL_PROTO=LL128;NCCL_DEBUG=INFO;NCCL_DEBUG_SUBSYS=INIT,TUNING|
W0D|NCCL_DEBUG=INFO;NCCL_DEBUG_SUBSYS=INIT,TUNING|
W0A||
C2A||--chunked_prefill_size=2048;--prefix_cache_snapshot_interval_pages=16
C2B||--chunked_prefill_size=2048;--prefix_cache_snapshot_interval_pages=16
CFGS

echo "--- restore prod $(date "+%T") ---"
sudo systemctl start fastllm-qwen38-tp4
RP=0
for i in $(seq 1 240); do
  code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8080/v1/models 2>/dev/null)
  if [ "$code" = "401" ] || [ "$code" = "200" ]; then RP=1; echo "PROD_READY http=$code after ~$((i*5))s"; break; fi
  sleep 5
done
K=$(grep -oP "VLLM_API_KEY=\K\S+" /home/ai-agent/qwen38-0.2x.env)
R=$(curl -s -m 60 http://127.0.0.1:8080/v1/chat/completions -H "Authorization: Bearer $K" -H "Content-Type: application/json" -d "{\"model\":\"Qwen3.8-27B-W8A16\",\"messages\":[{\"role\":\"user\",\"content\":\"仅回复 WB3_OK\"}],\"max_tokens\":16,\"temperature\":0}")
echo "post-check: $R" | head -c 280; echo
echo "WINDOWB3_DONE prod=$RP $(date "+%T")" >> $W/windowb3.status
echo "===== WINDOW-B3 END $(date "+%F %T") ====="
