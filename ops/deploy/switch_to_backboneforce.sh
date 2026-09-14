#!/bin/bash
# switch_to_backboneforce.sh — 转正 S9：生产 launcher FASTLLM_CUDA_DFLASH_TP_BACKBONE auto->force + 重启 + 验证。
# 回滚：rollback_backboneforce.sh
set -u
L=/home/ai-agent/fastllm-video-repro/fastllm_prod_launch.py
BK=$L.bak-pre-backboneforce-20260914
echo "===== SWITCH BACKBONE-FORCE $(date '+%F %T') ====="
echo "--- PHASE0 preflight ---"
grep -n "FASTLLM_CUDA_DFLASH_TP_BACKBONE" $L | head -3
[ -f $BK ] && echo "backup exists (ok)" || cp -a $L $BK
sed -i "s/FASTLLM_CUDA_DFLASH_TP_BACKBONE'\] = 'auto'/FASTLLM_CUDA_DFLASH_TP_BACKBONE'] = 'force'/" $L
grep -n "FASTLLM_CUDA_DFLASH_TP_BACKBONE" $L | head -3
python3 -m py_compile $L && echo "launcher syntax OK"
echo "--- PHASE1 restart prod ---"
sudo systemctl restart fastllm-qwen38-tp4
R=0
for i in $(seq 1 120); do
  code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8080/v1/models 2>/dev/null)
  if [ "$code" = "401" ] || [ "$code" = "200" ]; then R=1; echo "PROD_READY http=$code after ~$((i*3))s"; break; fi
  sleep 3
done
[ "$R" = 1 ] || { echo "RESTART_FAILED"; exit 1; }
echo "--- PHASE2 关键行 ---"
PLOG=/home/ai-agent/fastllm-video-repro/results/server-prod.service.log
sleep 5
tail -400 $PLOG | grep -a 'TP prepared\|backbone TP\|enabled: layers' | tail -4 | cut -c1-150
tail -400 $PLOG | grep -a 'session.*limit\|Yarn' | tail -2 | cut -c1-120
echo "--- PHASE3 decode 复测（scan_bench；期望 d200≈242 / c32_dec≈228） ---"
/home/ai-agent/builds/fastllm-video-venv/bin/python /home/ai-agent/builds/upgrade-test/scripts/scan_bench.py http://127.0.0.1:8080 /home/ai-agent/builds/upgrade-test/post_force_verify.json POSTFORCE || echo "BENCH_FAIL"
echo "===== SWITCH BACKBONE-FORCE END $(date '+%F %T') ====="
