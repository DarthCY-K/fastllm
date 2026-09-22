#!/bin/bash
# r13_soak.sh — 转正后实测盯梢（非破坏性：生产照常服务，只发请求 + 读日志）
# 腿：pins×3（含前缀复用路径）/ tail64×3（捕获与解码性能）/ 并发突发 + 前缀复用 / 长文针测 64K / 多模态
# 收尾：生产日志错误窗口 + 关键行为计数（prefix 命中、big-buffer trim、graph/capture 告警、OOM）
set -u
W=/home/ai-agent/builds/upgrade-test
VPY=/home/ai-agent/builds/fastllm-video-venv/bin/python
LOG=$W/r13-soak.log
STATUS=$W/r13-soak.status
L=/home/ai-agent/fastllm-video-repro/results/server-prod.service.log
exec > >(tee -a "$LOG") 2>&1
echo "========= R13 SOAK START $(date '+%F %T') ========="
B0=$(wc -l < $L)
echo "prod log baseline line=$B0  so=$(md5sum /home/ai-agent/builds/fastllm-video-venv/lib/python3.13/site-packages/ftllm/libfastllm_tools.so | cut -c1-12)"

pins() {
  local tag=$1
  $VPY $W/trial_probe2.py http://127.0.0.1:8080 $W/soak-probe-$tag.json > $W/soak-probe-$tag.out 2>&1 || echo "[$tag] PROBE_INCOMPLETE"
  local n=0; for m in f5de00c56dd1 30f8a5c9ee88 2adaf2269e77; do grep -q "$m" $W/soak-probe-$tag.out && n=$((n+1)); done
  echo "[$tag] pins=$n/3 $(grep -cE '^\[PASS\]' $W/soak-probe-$tag.out)/4 PASS  $(grep -aoE 'dec=[0-9.]+' $W/soak-probe-$tag.out | tr '\n' ' ')"
}

for i in 1 2 3; do pins "run$i"; done

for i in 1 2 3; do
  echo "[tail64 #$i] $($VPY $W/scripts/tail64_probe.py http://127.0.0.1:8080 2>&1 | tail -1)"
done

echo "--- 并发/前缀复用腿 $(date '+%T') ---"
$VPY $W/r13_soak_extra.py http://127.0.0.1:8080 2>&1 | tail -4

echo "--- 长文针测 64K（depth 20000）$(date '+%T') ---"
$VPY $W/scripts/needle_probe_swift.py http://127.0.0.1:8080 20000 64000 2>&1 | tail -2

echo "--- 多模态腿 $(date '+%T') ---"
$VPY $W/scripts/mmcache_probe_prod8080.py 2>&1 | tail -6

echo "--- 日志窗口分析 $(date '+%T') ---"
tail -n +$((B0+1)) $L > /tmp/soak-window.log
echo "errors=$(grep -ac 'FastLLM Error' /tmp/soak-window.log) traceback=$(grep -ac Traceback /tmp/soak-window.log) oom=$(grep -ac 'out of memory' /tmp/soak-window.log) capture_warn=$(grep -aicE 'capture (abort|fail)|graph.*(abort|fail)' /tmp/soak-window.log)"
echo "prefix_hit_lines=$(grep -acE 'prefix cache (hit|restore)|cached=' /tmp/soak-window.log) big_trim=$(grep -ac 'idle big-buffer' /tmp/soak-window.log) mtrace_grow=$(grep -ac 'big-grow' /tmp/soak-window.log)"
echo "http=$(grep -aoE 'HTTP/1.1\" [0-9]{3}' /tmp/soak-window.log | sort | uniq -c | tr '\n' ' ')"
echo "accept=$(grep -ao 'pos_accept_rate=\[[^]]*\]' /tmp/soak-window.log | tail -1)"
echo "非预期行（若有）:"; grep -aoiE 'FastLLM Error.*|Traceback.*|out of memory.*' /tmp/soak-window.log | head -5
cp /tmp/soak-window.log $W/soak-window.log
echo "SOAK_DONE $(date '+%F %T')" > $STATUS
cat $STATUS
echo "========= R13 SOAK END $(date '+%F %T') ========="
