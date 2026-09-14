#!/bin/bash
# switch_to_upgrade_r2.sh — 部署 r2 (master 21650fa + PR #731/#732/#730) 到生产 venv，重启并验证。
# 回滚：bash scripts/rollback_upgrade_r2.sh（恢复 ftllm.backup-20260914-pre-r2 = r1 生产包）
set -u
W=/home/ai-agent/builds/upgrade-test
V=/home/ai-agent/builds/fastllm-video-venv
PKG=$V/lib/python3.13/site-packages/ftllm
OVL=$W/overlay-r2/ftllm
BK=$V/lib/python3.13/site-packages/ftllm.backup-20260914-pre-r2
VPY=$V/bin/python
R=/home/ai-agent/fastllm-video-repro
PLOG=$R/results/server-prod.service.log
exec > >(tee -a $W/switch-r2.log) 2>&1
echo "===== SWITCH-R2 START $(date '+%F %T') ====="

echo "--- PHASE0 preflight ---"
[ -f $OVL/libfastllm_tools.so ] || { echo NO_OVERLAY_SO; exit 2; }
M=$(md5sum $OVL/libfastllm_tools.so | cut -d' ' -f1)
[ "$M" = "2d0894a26082360d1d3734bf4b30047a" ] || { echo BAD_OVERLAY_MD5=$M; exit 2; }
strings -a $OVL/libfastllm_tools.so | grep -q "ALLOW_YARN_WITH_DFLASH" || { echo NO_GATE; exit 2; }
strings -a $OVL/libfastllm_tools.so | grep -q "FASTLLM_QWEN35_FINAL_CHUNK_DECODE_MAX" || { echo NO_731_FINALCHUNK; exit 2; }
strings -a $OVL/libfastllm_tools.so | grep -q "FASTLLM_AUTOWARMUP_SPARE_KV_MB" || { echo NO_731_SPAREKV; exit 2; }
strings -a $OVL/libfastllm_tools.so | grep -q "FASTLLM_PREFIX_CACHE_SNAPSHOT_INTERVAL_PAGES" || { echo NO_730_SNAPINT; exit 2; }
grep -q "default_effort" $OVL/openai_server/fastllm_completion.py || { echo NO_MEDIUM_FIX; exit 2; }
echo "preflight ok (so md5=$M)"

echo "--- PHASE1 backup venv ftllm (current = r1) ---"
if [ ! -d $BK ]; then cp -a $PKG $BK && echo "backup done"; else echo "backup exists"; fi
du -sh $BK 2>/dev/null

echo "--- PHASE2 sync overlay-r2 -> venv ---"
$VPY $W/scripts/sync_tree.py $OVL $PKG || { echo SYNC_FAIL; exit 3; }

echo "--- PHASE3 verify venv ---"
md5sum $OVL/libfastllm_tools.so $PKG/libfastllm_tools.so
sha256sum $OVL/openai_server/fastllm_completion.py $PKG/openai_server/fastllm_completion.py
echo "default_effort count: $(grep -c default_effort $PKG/openai_server/fastllm_completion.py)"
echo "gate count: $(strings -a $PKG/libfastllm_tools.so | grep -c ALLOW_YARN_WITH_DFLASH)"
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
if [ "$RP" != "1" ]; then echo "PROD_NOT_READY — rollback: bash $W/scripts/rollback_upgrade_r2.sh"; exit 5; fi

echo "--- PHASE5 新启动窗口关键行 ---"
tail -n +$((W0+1)) $PLOG | grep -aE "fastllm-experimental|context window limit|KV Cache Token limit|DFlash2\] enabled|AutoWarmup GPU 0|Traceback|Error" | head -20

echo "--- PHASE6 行为指纹: ~2.2K 冷预填的 seeded 行应 chunk=256 (r2 默认) ---"
$VPY $W/scripts/chunk_probe.py && tail -300 $PLOG | grep -a "long prefill cache seeded" | tail -3

echo "SWITCH_DONE ready=$RP sw=r2" > $W/switch-r2.status
echo "===== SWITCH-R2 END $(date '+%F %T') ====="
