#!/bin/bash
# run_build_mmguard.sh — 后台启动 mmguard 构建（脱离 ssh 会话）并立即返回。
cd /home/ai-agent/builds/upgrade-test
setsid bash scripts/build-mmguard.sh > build-mmguard.run.log 2>&1 < /dev/null &
echo "LAUNCHED pid=$!"
