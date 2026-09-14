#!/bin/bash
# rollback_nccl_ll128.sh — 回滚 NCCL_PROTO=LL128 转正（恢复 launcher 备份 + 重启验证）
set -u
P=/home/ai-agent/fastllm-video-repro/fastllm_prod_launch.py
BK=$P.bak-pre-ncclll128-20260914
W=/home/ai-agent/builds/upgrade-test
exec > >(tee -a $W/rollback-ncclll128.log) 2>&1
echo "===== ROLLBACK NCCL_LL128 START $(date '+%F %T') ====="
[ -f $BK ] || { echo "NO_BACKUP $BK"; exit 2; }
cp -p $BK $P
grep -c "NCCL_PROTO" $P && { echo "STILL_PRESENT"; exit 3; }
sudo systemctl restart fastllm-qwen38-tp4
RP=0
for i in $(seq 1 240); do
  code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8080/v1/models 2>/dev/null)
  if [ "$code" = "401" ] || [ "$code" = "200" ]; then RP=1; echo "PROD_READY after ~$((i*5))s"; break; fi
  sleep 5
done
PID=$(systemctl show fastllm-qwen38-tp4 -p MainPID --value)
echo "PID=$PID"
tr '\0' '\n' < /proc/$PID/environ | grep -E "^NCCL_PROTO=" || echo "NCCL_PROTO absent (expected)"
echo "ROLLBACK_NCCL_LL128_DONE ready=$RP" > $W/rollback-ncclll128.status
echo "===== ROLLBACK NCCL_LL128 END $(date '+%F %T') ====="
