#!/bin/bash
# switch_to_dflashfix.sh — 部署 DFlash 尾块修复（overlay-fix）到生产 venv，重启并验证。
# 回滚：bash scripts/rollback_dflashfix.sh（恢复 ftllm.backup-20260914-pre-dflashfix）
set -u
W=/home/ai-agent/builds/upgrade-test
V=/home/ai-agent/builds/fastllm-video-venv
PKG=$V/lib/python3.13/site-packages/ftllm
OVL=$W/overlay-fix/ftllm
BK=$V/lib/python3.13/site-packages/ftllm.backup-20260914-pre-dflashfix
VPY=$V/bin/python
R=/home/ai-agent/fastllm-video-repro
PLOG=$R/results/server-prod.service.log
exec > >(tee -a $W/switch-dflashfix.log) 2>&1
echo "===== SWITCH-DFLASHFIX START $(date '+%F %T') ====="

echo "--- PHASE0 preflight ---"
[ -f $OVL/libfastllm_tools.so ] || { echo NO_OVERLAY_SO; exit 2; }
M=$(md5sum $OVL/libfastllm_tools.so | cut -d' ' -f1)
echo "overlay-fix so md5=$M"
strings -a $OVL/libfastllm_tools.so | grep -q "ALLOW_YARN_WITH_DFLASH" || { echo NO_GATE; exit 2; }
strings -a $OVL/libfastllm_tools.so | grep -q "FASTLLM_QWEN35_FINAL_CHUNK_DECODE_MAX" || { echo NO_731; exit 2; }
strings -a $OVL/libfastllm_tools.so | grep -q "FASTLLM_PREFIX_CACHE_SNAPSHOT_INTERVAL_PAGES" || { echo NO_730; exit 2; }
grep -q "default_effort" $OVL/openai_server/fastllm_completion.py || { echo NO_MEDIUM_FIX; exit 2; }

echo "--- PHASE1 backup venv ftllm ---"
if [ ! -d $BK ]; then cp -a $PKG $BK && echo "backup done"; else echo "backup exists"; fi
du -sh $BK 2>/dev/null

echo "--- PHASE2 sync overlay-fix -> venv ---"
$VPY $W/scripts/sync_tree.py $OVL $PKG || { echo SYNC_FAIL; exit 3; }

echo "--- PHASE3 verify venv ---"
md5sum $OVL/libfastllm_tools.so $PKG/libfastllm_tools.so
$VPY -c "import ftllm; import ftllm.openai_server.fastllm_completion as fc; print('import ok:', ftllm.__file__)" || { echo IMPORT_FAIL; exit 4; }

echo "--- PHASE4 restart prod ---"
W0=$(wc -l < $PLOG 2>/dev/null || echo 0)
sudo systemctl restart fastllm-qwen38-tp4
RP=0
for i in $(seq 1 240); do
  code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8080/v1/models 2>/dev/null)
  if [ "$code" = "401" ] || [ "$code" = "200" ]; then RP=1; echo "PROD_READY after ~$((i*5))s"; break; fi
  sleep 5
done
if [ "$RP" != "1" ]; then echo "PROD_NOT_READY — rollback: bash $W/scripts/rollback_dflashfix.sh"; exit 5; fi

echo "--- PHASE5 新启动窗口关键行 ---"
tail -n +$((W0+1)) $PLOG | grep -aE "fastllm-experimental|context window limit|KV Cache Token limit|DFlash2\] enabled|Traceback" | head -12

echo "--- PHASE6 行为指纹：16K 尾块(11) 复现探针（应出现 seeded 行、无 not aligned、decode~200）---"
$VPY $W/scripts/tail64_probe.py http://127.0.0.1:8080 || true
tail -300 $PLOG | grep -aE "long prefill cache seeded|not aligned" | tail -4
echo "SWITCH_DONE ready=$RP pkg=dflashfix" > $W/switch-dflashfix.status
echo "===== SWITCH-DFLASHFIX END $(date '+%F %T') ====="
