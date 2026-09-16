#!/bin/bash
# switch_prod_nvfp4.sh — 把生产 argv 的模型路径切到 NVFP4 包（含视觉塔），单变量：只改 model 路径。
# 生产单元 fastllm-qwen38-tp4 不变；失败自动回滚（恢复 argv 备份 + 重启 + 等就绪）。
set -u
R=/home/ai-agent/fastllm-video-repro
A=$R/results/argv-prod-tp4.json
BK=$A.bak-pre-nvfp4-20260916
W=/home/ai-agent/builds/upgrade-test
V=/home/ai-agent/builds/fastllm-video-venv
VPY=$V/bin/python
PLOG=$R/results/server-prod.service.log
STATUS=$W/switch-nvfp4.status
LOG=$W/switch-nvfp4.log
FP8=/home/ai-agent/fastllm-video-repro/models/nerkyor/Qwen3.8-27B-EfficientThink-FP8-lm
NVP4=/home/ai-agent/staging/nvfp4-w4a16
exec > >(tee -a $LOG) 2>&1
echo "===== SWITCH-NVFP4 START $(date '+%F %T') ====="
echo "r5 .so md5 = $(md5sum $V/lib/python3.13/site-packages/ftllm/libfastllm_tools.so 2>/dev/null | cut -d' ' -f1)"

wait_ready () {
  local n=0
  for i in $(seq 1 240); do
    code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8080/v1/models 2>/dev/null)
    if [ "$code" = "401" ] || [ "$code" = "200" ]; then echo "$((i*5))"; return 0; fi
    sleep 5
  done
  return 1
}

restore_argv () {
  if [ -f $BK ]; then cp -a $BK $A; cp -a $BK $A.backupactive; echo "argv restored from $BK"; fi
}

# PHASE0：备份 + 单变量改写 argv
[ -f $BK ] || { cp -a $A $BK && echo "argv backup -> $BK"; }
$VPY - <<PY || { echo "ARGV_EDIT_FAIL"; echo "SWITCH_NVFP4_ABORT argv" > $STATUS; exit 2; }
import json, sys
p = "$A"
d = json.load(open(p))
argv = d["argv"]
fp8, nvp4 = "$FP8", "$NVP4"
if fp8 in argv:
    argv[argv.index(fp8)] = nvp4
    print("argv model path ->", nvp4)
elif nvp4 in argv:
    print("argv already NVFP4 (idempotent)")
else:
    print("FATAL: neither path present"); sys.exit(1)
d["comment"] = "prod argv — NVFP4 W4A16 (vision-capable) since 2026-09-16; only the model path differs from the ET-FP8 baseline"
json.dump(d, open(p, "w"), ensure_ascii=False, indent=2)
PY
python3 -c "import json;print('argv model path now =', [x for x in json.load(open('$A'))['argv'] if 'models/' in x or 'staging/' in x][0])"

W0=$(wc -l < $PLOG)
echo "--- PHASE1 restart $(date '+%T') ---"
sudo systemctl restart fastllm-qwen38-tp4
T=$(wait_ready) || { echo "PROD_NOT_READY"; tail -40 $PLOG; restore_argv; sudo systemctl restart fastllm-qwen38-tp4; wait_ready >/dev/null && echo "ROLLED_BACK_READY"; echo "SWITCH_NVFP4_NOT_READY argv_restored" > $STATUS; exit 3; }
echo "PROD_READY after ~${T}s"

echo "--- PHASE2 启动指纹（自重启起） ---"
tail -n +$((W0+1)) $PLOG | grep -E "AutoWarmup GPU|KV Cache Token limit|DFlash2\] enabled|DFlash2\] TP prepared|multimodal|vision|Traceback" | head -12

echo "--- PHASE3 功能电池（post_switch_probe，含 count200 md5 对锚） ---"
PROBE_OK=0
$VPY $W/post_switch_probe.py http://127.0.0.1:8080 $W/switch-nvfp4-probe.json POST_NVFP4 && PROBE_OK=1 || echo "PROBE_FAIL"

echo "--- PHASE4 图像端到端（三色轮换） ---"
IMG_OK=0
$VPY $W/nvfp4_image_probe.py http://127.0.0.1:8080 $W/switch-nvfp4-image.json POST_NVFP4_IMG && IMG_OK=1 || echo "IMAGE_PROBE_FAIL"

if [ "$PROBE_OK" = "1" ] && [ "$IMG_OK" = "0" ]; then
  echo "WARN: 文本电池通过但图像未命中 —— 保留 NVFP4，人工判断（不自动回滚）"
fi

echo "--- PHASE5 尾块≤64 收敛探针 ---"
$VPY $W/r5_tail_probe2.py http://127.0.0.1:8080 $W/switch-nvfp4-tail.json POST_NVFP4_TAIL || echo "TAIL_INCOMPLETE"

echo "--- PHASE6 日志计数（自重启起） ---"
printf "seeded=%s restored=%s desync=%s vision_fail=%s traceback=%s\n" \
  "$(tail -n +$((W0+1)) $PLOG | grep -c 'long prefill cache seeded')" \
  "$(tail -n +$((W0+1)) $PLOG | grep -c 'prefix cache restored')" \
  "$(tail -n +$((W0+1)) $PLOG | grep -c 'draft cache is not aligned')" \
  "$(tail -n +$((W0+1)) $PLOG | grep -c 'multimodal request failed')" \
  "$(tail -n +$((W0+1)) $PLOG | grep -c 'Traceback')"
echo "--- PHASE7 显存（NVFP4 预期比 FP8 每卡少 ~2GB） ---"
nvidia-smi --query-gpu=index,memory.used,temperature.gpu --format=csv,noheader
echo "SWITCH_NVFP4_DONE probe=$PROBE_OK image=$IMG_OK ready=${T}s $(date '+%F %T')" > $STATUS
echo "回滚命令：bash $W/scripts/rollback_prod_nvfp4.sh"
echo "===== SWITCH-NVFP4 END $(date '+%F %T') ====="
