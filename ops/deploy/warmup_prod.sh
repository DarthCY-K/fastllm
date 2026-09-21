#!/bin/bash
# warmup_prod.sh — 吸收 SSD 首请求"全量读取校验"一次性开销（≈存储字节/295MB/s）
# 用法：bash warmup_prod.sh [超时秒数，默认360]
set -u
T=${1:-360}
K=$(grep -h '^VLLM_API_KEY=' /home/ai-agent/qwen38-0.2x.env | head -1 | cut -d= -f2- | tr -d '"'"'"' ')
printf '{"model":"Qwen3.8-27B","messages":[{"role":"user","content":"warmup"}],"max_tokens":4,"temperature":0}' > /tmp/warmup_ping.json
for i in $(seq 1 60); do
  code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8080/v1/models 2>/dev/null)
  if [ "$code" = "401" ] || [ "$code" = "200" ]; then break; fi
  sleep 5
done
t0=$(date +%s)
curl -s -o /tmp/warmup_resp.json -m $T -H "Authorization: Bearer $K" -H "Content-Type: application/json" -d @/tmp/warmup_ping.json http://127.0.0.1:8080/v1/chat/completions
rc=$?
t1=$(date +%s)
echo "warmup: rc=$rc elapsed=$((t1-t0))s store=$(du -sh /home/ai-agent/prefix_ssd_prod 2>/dev/null | cut -f1)"
