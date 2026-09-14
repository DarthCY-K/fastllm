#!/bin/bash
# run_window_b.sh — 2026-09-14 夜打包窗口（A1 NCCL 四档 + A2 预填块 1024/2048 + A3 保留数 2/4/8）
# 纪律：停生产 → 逐配置起 8081 测试栈 → bench → 下一配置 → EXIT 恢复生产。
set -u
W=/home/ai-agent/builds/upgrade-test
V=/home/ai-agent/builds/fastllm-video-venv
VPY=$V/bin/python
NCCL_LIB=/home/ai-agent/builds/fastllm-test-venv/lib/python3.13/site-packages/nvidia/nccl/lib
BENCH=$W/repo/tools/nccl_latency_bench/nccl_latency_bench
exec > >(tee -a $W/windowb.log) 2>&1
trap 'systemctl is-active --quiet fastllm-qwen38-tp4 || sudo systemctl start fastllm-qwen38-tp4' EXIT

echo "===== WINDOW-B START $(date "+%F %T") ====="
rm -f $W/windowb.status $W/WINDOWB_STOP

echo "--- stop prod $(date "+%T") ---"
sudo systemctl stop fastllm-qwen38-tp4
for i in $(seq 1 40); do systemctl is-active --quiet fastllm-qwen38-tp4 || break; sleep 1; done
sleep 5
nvidia-smi --query-gpu=index,memory.used --format=csv,noheader

echo "--- NCCL bench phase $(date "+%T") ---" | tee -a $W/windowb.status
cd $W/repo/tools/nccl_latency_bench
for pair in 0,3 0,1; do
  for cfg in "" "NCCL_PROTO=LL128" "NCCL_ALGO=Tree" "NCCL_PROTO=LL128 NCCL_ALGO=Tree" "NCCL_PROTO=LL"; do
    echo "### bench pair=$pair cfg=[${cfg:-auto}] $(date "+%T")"
    timeout 300 env LD_LIBRARY_PATH=$NCCL_LIB $cfg $BENCH --devices $pair --bytes 4K,8K,16K --warmup 100 --iters 1000 --batch-iters 2000 || echo "BENCH_ERR pair=$pair cfg=[${cfg:-auto}]"
  done
done
echo "bench phase done $(date "+%T")" >> $W/windowb.status

run_bench() { # $1=tag $2=bench
  local tag=$1 bench=$2
  local out=$W/wb_${tag}_${bench}.json
  case $bench in
    scan)  $VPY $W/scripts/scan_bench.py  http://127.0.0.1:8081 $out ${tag}_${bench} || echo "BENCH_FAIL $tag $bench";;
    scan2) $VPY $W/scripts/scan_bench2.py http://127.0.0.1:8081 $out ${tag}_${bench} || echo "BENCH_FAIL $tag $bench";;
    mt)    $VPY $W/scripts/ab7b_mt.py     http://127.0.0.1:8081 $out ${tag}_${bench} || echo "BENCH_FAIL $tag $bench";;
  esac
}

run_cfg() { # $1=tag $2=benches(+ 分隔) $3=SCAN_ENV $4=SCAN_ARGV
  local tag=$1 benches=$2 senv=$3 sargv=$4
  echo "--- cfg $tag benches=$benches env=[$senv] argv=[$sargv] $(date "+%T") ---"
  cd $W
  SCAN_ENV="$senv" SCAN_ARGV="$sargv" nohup $VPY $W/scripts/scan_launch.py > $W/stack-wb-$tag.log 2>&1 &
  local P=$!
  echo $P > $W/stack-wb-$tag.pid
  local R=0
  for i in $(seq 1 240); do
    local code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8081/v1/models 2>/dev/null)
    if [ "$code" = "401" ] || [ "$code" = "200" ]; then R=1; echo "$tag READY http=$code after ~$((i*5))s"; break; fi
    kill -0 $P 2>/dev/null || { echo "$tag DIED — tail:"; tail -8 $W/stack-wb-$tag.log; break; }
    sleep 5
  done
  if [ "$R" = 1 ]; then
    grep -a "scan_launch]" $W/stack-wb-$tag.log | head -3
    local b
    for b in ${benches//+/ }; do
      run_bench "$tag" "$b"
    done
  fi
  kill $P 2>/dev/null; sleep 10; kill -9 $P 2>/dev/null
  for i in $(seq 1 40); do
    local used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits -i 0)
    [ "$used" -lt 3000 ] && break
    sleep 2
  done
  echo "$tag done $(date "+%T")" >> $W/windowb.status
}

while IFS='|' read -r tag benches senv sargv; do
  [ -z "${tag:-}" ] && continue
  [ -f $W/WINDOWB_STOP ] && { echo "WINDOWB_STOP detected"; break; }
  run_cfg "$tag" "$benches" "${senv:-}" "${sargv:-}"
done <<'CFGS'
W0|scan2+mt||
W1|scan|NCCL_PROTO=LL128|
W2|scan|NCCL_ALGO=Tree|
W3|scan|NCCL_PROTO=LL128;NCCL_ALGO=Tree|
C1|scan2||--chunked_prefill_size=1024;--prefix_cache_snapshot_interval_pages=8
C2|scan2||--chunked_prefill_size=2048;--prefix_cache_snapshot_interval_pages=16
P2|mt+scan|FASTLLM_PREFIX_CACHE_SNAPSHOT_MAX_PER_REQUEST=2|
P4|mt+scan|FASTLLM_PREFIX_CACHE_SNAPSHOT_MAX_PER_REQUEST=4|
P8|mt+scan|FASTLLM_PREFIX_CACHE_SNAPSHOT_MAX_PER_REQUEST=8|
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
R=$(curl -s -m 60 http://127.0.0.1:8080/v1/chat/completions -H "Authorization: Bearer $K" -H "Content-Type: application/json" -d "{\"model\":\"Qwen3.8-27B-W8A16\",\"messages\":[{\"role\":\"user\",\"content\":\"仅回复 WB_OK\"}],\"max_tokens\":16,\"temperature\":0}")
echo "post-check: $R" | head -c 280; echo
echo "WINDOWB_DONE prod=$RP $(date "+%T")" >> $W/windowb.status
echo "===== WINDOW-B END $(date "+%F %T") ====="
