#!/bin/bash
# apply_nccl_ll128.sh — 生产启用 NCCL_PROTO=LL128（窗口证据：c32 预填 -14%、c64 -12%、decode 不变、md5 不变）
# 依据：upgrade-test/wb_*/wb2_*/wb3_*（2026-09-14 夜三窗口）；等价改动 = prod launcher 加一行 env。
# 失败自动回滚：NOT_READY 分支会恢复备份并重启。
# 回滚：bash scripts/rollback_nccl_ll128.sh
set -u
P=/home/ai-agent/fastllm-video-repro/fastllm_prod_launch.py
BK=$P.bak-pre-ncclll128-20260914
W=/home/ai-agent/builds/upgrade-test
PLOG=/home/ai-agent/fastllm-video-repro/results/server-prod.service.log
exec > >(tee -a $W/apply-ncclll128.log) 2>&1
echo "===== APPLY NCCL_LL128 START $(date '+%F %T') ====="

echo "--- PHASE0 preflight ---"
python3 - <<'PY' || { echo PREFLIGHT_FAIL; exit 2; }
src = open('/home/ai-agent/fastllm-video-repro/fastllm_prod_launch.py').read()
assert 'NCCL_PROTO' not in src, 'NCCL_PROTO already present?'
assert "FASTLLM_CUDA_DFLASH_TP_BACKBONE'] = 'force'" in src, 'backbone force expected (current baseline)'
assert "FASTLLM_ALLOW_YARN_WITH_DFLASH'] = '1'" in src, 'yarn gate expected'
print('preflight ok')
PY

echo "--- PHASE1 backup ---"
[ -f $BK ] || cp -p $P $BK
md5sum $P $BK

echo "--- PHASE2 patch ---"
python3 - <<'PY'
p = '/home/ai-agent/fastllm-video-repro/fastllm_prod_launch.py'
src = open(p).read()
anchor = "os.environ['FASTLLM_ALLOW_YARN_WITH_DFLASH'] = '1'"
assert anchor in src
add = ("# 2026-09-14 夜：NCCL 小消息延迟（LL128 强制 -> NCCL 实际选 TREE+LL128；\n"
       "# 窗口证据：c32 预填 34.0->29.1s(-14%)、c64 67.9->59.7s(-12%)、decode 不变、输出 md5 不变；\n"
       "# 见 upgrade-test/ wb_/wb2_/wb3_ 系列 + ops/docs/推理机-NCCL预填保留扫描-2026-09-14夜.md）\n"
       "os.environ['NCCL_PROTO'] = 'LL128'\n")
src = src.replace(anchor, add + anchor, 1)
open(p, 'w').write(src)
src2 = open(p).read()
assert "os.environ['NCCL_PROTO'] = 'LL128'" in src2
for k in ("FASTLLM_CUDA_DFLASH_TP_BACKBONE'] = 'force'", "FASTLLM_ALLOW_YARN_WITH_DFLASH'] = '1'"):
    assert k in src2
print('patched: NCCL_PROTO=LL128 inserted before yarn gate line')
PY

echo "--- PHASE3 restart ---"
W0L=$(wc -l < $PLOG 2>/dev/null || echo 0)
sudo systemctl restart fastllm-qwen38-tp4
RP=0
for i in $(seq 1 240); do
  code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8080/v1/models 2>/dev/null)
  if [ "$code" = "401" ] || [ "$code" = "200" ]; then RP=1; echo "PROD_READY after ~$((i*5))s"; break; fi
  sleep 5
done
if [ "$RP" != "1" ]; then
  echo "NOT_READY — AUTO-ROLLBACK"
  cp -p $BK $P
  sudo systemctl restart fastllm-qwen38-tp4
  RP2=0
  for i in $(seq 1 240); do
    code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8080/v1/models 2>/dev/null)
    if [ "$code" = "401" ] || [ "$code" = "200" ]; then RP2=1; echo "ROLLBACK_READY after ~$((i*5))s"; break; fi
    sleep 5
  done
  echo "APPLY_NCCL_LL128_FAILED rolled_back=$RP2" > $W/apply-ncclll128.status
  echo "===== APPLY NCCL_LL128 END (FAILED, rolled_back=$RP2) $(date '+%F %T') ====="
  exit 5
fi

echo "--- PHASE4 verify (env + probe + 新窗口 Traceback) ---"
PID=$(systemctl show fastllm-qwen38-tp4 -p MainPID --value)
echo "PID=$PID"
tr '\0' '\n' < /proc/$PID/environ | grep -E "^NCCL_PROTO=|^FASTLLM_CUDA_DFLASH_TP_BACKBONE=|^FASTLLM_ALLOW_YARN_WITH_DFLASH=" || echo "ENV_MISSING!"
K=$(grep -oP "VLLM_API_KEY=\K\S+" /home/ai-agent/qwen38-0.2x.env)
R=$(curl -s -m 60 http://127.0.0.1:8080/v1/chat/completions -H "Authorization: Bearer $K" -H "Content-Type: application/json" -d '{"model":"Qwen3.8-27B-W8A16","messages":[{"role":"user","content":"仅回复：LL128已生效"}],"max_tokens":16,"temperature":0}')
echo "probe: $R" | head -c 300; echo
echo "Traceback count in new window: $(tail -n +$((W0L+1)) $PLOG | grep -ac Traceback)"

echo "APPLY_NCCL_LL128_DONE ready=$RP" > $W/apply-ncclll128.status
echo "===== APPLY NCCL_LL128 END $(date '+%F %T') ====="
