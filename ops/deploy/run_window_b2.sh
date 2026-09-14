#!/bin/bash
# run_window_b2.sh — LL128 预填增益确认窗（2×基线 + 2×LL128 交错复测；首对带 NCCL_DEBUG 取证）
# 纪律：停生产 → 逐配置起 8081 测试栈 → scan2 bench → 下一配置 → EXIT 恢复生产。
set -u
W=/home/ai-agent/builds/upgrade-test
V=/home/ai-agent/builds/fastllm-video-venv
VPY=$V/bin/python
exec > >(tee -a $W/windowb2.log) 2>&1
trap 'systemctl is-active --quiet fastllm-qwen38-tp4 || sudo systemctl start fastllm-qwen38-tp4' EXIT

echo "===== WINDOW-B2 START $(date "+%F %T") ====="
rm -f $W/windowb2.status $W/WINDOWB2_STOP

echo "--- stop prod $(date "+%T") ---"
sudo systemctl stop fastllm-qwen38-tp4
for i in $(seq 1 40); do systemctl is-active --quiet fastllm-qwen38-tp4 || break; sleep 1; done
sleep 5
nvidia-smi --query-gpu=index,memory.used --format=csv,noheader

run_bench() { # $1=tag
  local tag=$1
  local out=$W/wb2_${tag}.json
  nvidia-smi --query-gpu=index,clocks.sm,clocks.mem,power.draw,temperature.gpu --format=csv,noheader -lms 1000 > $W/wb2_clocks_${tag}.log 2>&1 &
  local SM=$!
  $VPY $W/scripts/scan_bench2b.py http://127.0.0.1:8081 $out ${tag} || echo "BENCH_FAIL $tag"
  kill $SM 2>/dev/null
}

run_cfg() { # $1=tag $2=SCAN_ENV
  local tag=$1 senv=$2
  echo "--- cfg $tag env=[$senv] $(date "+%T") ---"
  cd $W
  SCAN_ENV="$senv" SCAN_ARGV="" nohup $VPY $W/scripts/scan_launch.py > $W/stack-wb2-$tag.log 2>&1 &
  local P=$!
  echo $P > $W/stack-wb2-$tag.pid
  local R=0
  for i in $(seq 1 240); do
    local code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8081/v1/models 2>/dev/null)
    if [ "$code" = "401" ] || [ "$code" = "200" ]; then R=1; echo "$tag READY http=$code after ~$((i*5))s"; break; fi
    kill -0 $P 2>/dev/null || { echo "$tag DIED — tail:"; tail -8 $W/stack-wb2-$tag.log; break; }
    sleep 5
  done
  if [ "$R" = 1 ]; then
    grep -a "scan_launch]" $W/stack-wb2-$tag.log | head -3
    grep -aiE "LL128|AllReduce:|Connected|NCCL Initialized|Tuning" $W/stack-wb2-$tag.log | head -20
    run_bench "$tag"
    grep -a "Speed:" $W/stack-wb2-$tag.log | tail -4
  fi
  kill $P 2>/dev/null; sleep 10; kill -9 $P 2>/dev/null
  for i in $(seq 1 40); do
    local used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits -i 0)
    [ "$used" -lt 3000 ] && break
    sleep 2
  done
  echo "$tag done $(date "+%T")" >> $W/windowb2.status
}

while IFS='|' read -r tag senv; do
  [ -z "${tag:-}" ] && continue
  [ -f $W/WINDOWB2_STOP ] && { echo "WINDOWB2_STOP detected"; break; }
  run_cfg "$tag" "${senv:-}"
done <<'CFGS'
W0r|NCCL_DEBUG=INFO
W1r|NCCL_PROTO=LL128;NCCL_DEBUG=INFO;NCCL_DEBUG_SUBSYS=INIT,TUNING
W0r2|
W1r2|NCCL_PROTO=LL128
W0r3|
W1r3|NCCL_PROTO=LL128
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
R=$(curl -s -m 60 http://127.0.0.1:8080/v1/chat/completions -H "Authorization: Bearer $K" -H "Content-Type: application/json" -d "{\"model\":\"Qwen3.8-27B-W8A16\",\"messages\":[{\"role\":\"user\",\"content\":\"仅回复 WB2_OK\"}],\"max_tokens\":16,\"temperature\":0}")
echo "post-check: $R" | head -c 280; echo
echo "WINDOWB2_DONE prod=$RP $(date "+%T")" >> $W/windowb2.status
echo "===== WINDOW-B2 END $(date "+%F %T") ====="
