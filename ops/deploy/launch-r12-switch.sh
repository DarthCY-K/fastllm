#!/bin/bash
# launch-r12-switch.sh — 后台执行 r12 转正（switch_to_r12.sh）
cd /home/ai-agent/builds/upgrade-test || exit 1
setsid nohup bash /home/ai-agent/builds/upgrade-test/wt-r12/ops/deploy/switch_to_r12.sh > /home/ai-agent/builds/upgrade-test/run-r12-switch.run.log 2>&1 < /dev/null &
echo "LAUNCHED PID $!"
sleep 12
echo "--- switch-r12.log 头部 ---"
head -30 /home/ai-agent/builds/upgrade-test/switch-r12.log 2>/dev/null
echo "--- prod ---"
systemctl is-active fastllm-qwen38-tp4
