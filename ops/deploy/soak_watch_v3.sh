#!/bin/bash
# soak_watch.sh v3 — 每5分钟轻量巡检（v3: +seeded/skip 降级计数；每轮重读密钥）
W=/home/ai-agent/builds/upgrade-test
S=$W/soak.log
PLOG=/home/ai-agent/fastllm-video-repro/results/server-prod.service.log
echo "# soak start $(date '+%F %T') build=r2+dflashfix+backboneforce" >> $S
while true; do
  TS=$(date '+%F %T')
  ACT=$(systemctl is-active fastllm-qwen38-tp4)
  HTTP=$(curl -s -o /dev/null -m 5 -w "%{http_code}" http://127.0.0.1:8080/v1/models 2>/dev/null)
  K=$(sed -n "s/^VLLM_API_KEY=//p" /home/ai-agent/qwen38-0.2x.env | head -1 | tr -d "\042\047")
  R=$(curl -s -m 60 http://127.0.0.1:8080/v1/chat/completions -H "Authorization: Bearer $K" -H "Content-Type: application/json" -d "{\"model\":\"Qwen3.8-27B-W8A16\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly SOAK_OK\"}],\"max_tokens\":16,\"chat_template_kwargs\":{\"enable_thinking\":false}}" 2>/dev/null | head -c 400)
  if echo "$R" | grep -q SOAK_OK; then OKF=1; else OKF=0; fi
  SEED=$(grep -ac 'long prefill cache seeded' $PLOG 2>/dev/null || echo 0)
  SKIP=$(grep -acE 'not aligned|without speculative|not seeded' $PLOG 2>/dev/null || echo 0)
  GPU=$(nvidia-smi --query-gpu=memory.used,temperature.gpu --format=csv,noheader 2>/dev/null | tr "\n" "|")
  echo "$TS active=$ACT http=$HTTP ok=$OKF seed=$SEED skip=$SKIP gpu=$GPU" >> $S
  sleep 300
done
