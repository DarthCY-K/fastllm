#!/bin/bash
# restart_soak.sh — 清理旧 soak_watch 进程并启动 v3（带 seed/skip 计数）。
set -u
pkill -f "soak_watch" 2>/dev/null
sleep 2
for i in 1 2 3 4 5; do pgrep -f "soak_watch" >/dev/null || break; sleep 1; done
echo "--- 残留（应为空）:"
pgrep -af "soak_watch" | head -5 || echo "(none)"
cd /home/ai-agent/builds/upgrade-test
setsid nohup bash scripts/soak_watch_v3.sh > /dev/null 2>&1 < /dev/null &
sleep 3
echo "--- 新进程:"
pgrep -af "soak_watch_v3" | head -3
sleep 10
echo "--- soak.log 尾部:"
tail -3 /home/ai-agent/builds/upgrade-test/soak.log
echo "SOAK_RESTART_DONE"
