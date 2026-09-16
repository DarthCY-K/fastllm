#!/bin/bash
# switch_to_r5.sh — 部署 r5（fork sm75-2080Ti @e3b65d3b = 上游 61c288a9c 合并 + #726/#663 carry）到生产 venv。
# 回滚：bash scripts/rollback_r5.sh（恢复 ftllm.backup-20260916-pre-r5）
set -u
W=/home/ai-agent/builds/upgrade-test
V=/home/ai-agent/builds/fastllm-video-venv
PKG=$V/lib/python3.13/site-packages/ftllm
OVL=$W/overlay-r5/ftllm
BK=$V/lib/python3.13/site-packages/ftllm.backup-20260916-pre-r5
VPY=$V/bin/python
R=/home/ai-agent/fastllm-video-repro
PLOG=$R/results/server-prod.service.log
SO_EXPECT=06779c196df5a944c95dd25fde8d491f
PARSER_EXPECT=b253557592c542888568f44374a258df
exec > >(tee -a $W/switch-r5.log) 2>&1
echo "===== SWITCH-R5 START $(date '+%F %T') ====="

echo "--- PHASE0 preflight ---"
[ -f $OVL/libfastllm_tools.so ] || { echo NO_OVERLAY_SO; exit 2; }
M=$(md5sum $OVL/libfastllm_tools.so | cut -d' ' -f1); echo "overlay-r3 so md5=$M"
[ "$M" = "$SO_EXPECT" ] || { echo "SO_MD5_MISMATCH expect=$SO_EXPECT"; exit 2; }
for s in ALLOW_YARN_WITH_DFLASH selector_q FASTLLM_TP2_MLP_OVERLAP FASTLLM_QWEN35_FINAL_CHUNK_DECODE_MAX FASTLLM_PREFIX_CACHE_SNAPSHOT_INTERVAL_PAGES; do
  c=$(strings -a $OVL/libfastllm_tools.so | grep -c "$s"); echo "  gate $s=$c"
  [ "$c" -ge 1 ] || { echo "MISSING_GATE $s"; exit 2; }
done
grep -q "default_effort" $OVL/openai_server/fastllm_completion.py || { echo NO_MEDIUM_FIX; exit 2; }
P=$(md5sum $OVL/openai_server/tool_parsers/qwen3coder_tool_parser.py | cut -d' ' -f1)
[ "$P" = "$PARSER_EXPECT" ] || { echo "PARSER_MD5_MISMATCH $P"; exit 2; }
echo "python 层标记 OK (default_effort + 重复参数宽容 $P)"
echo "-- venv 专属文件补齐（libnuma/libfastllm_tools-cpu 等）:"
for f in libnuma.so.1 libfastllm_tools-cpu.so; do
  if [ -f "$PKG/$f" ] && [ ! -f "$OVL/$f" ]; then cp -a "$PKG/$f" "$OVL/$f" && echo "  copied $f"; fi
done

echo "--- PHASE1 backup venv ftllm ---"
if [ ! -d $BK ]; then cp -a $PKG $BK && echo "backup done -> $BK"; else echo "backup exists -> $BK"; fi
du -sh $BK 2>/dev/null

echo "--- PHASE2 sync overlay-r3 -> venv ---"
$VPY $W/scripts/sync_tree.py $OVL $PKG || { echo SYNC_FAIL; exit 3; }

echo "--- PHASE3 verify venv ---"
md5sum $OVL/libfastllm_tools.so $PKG/libfastllm_tools.so
md5sum $OVL/openai_server/tool_parsers/qwen3coder_tool_parser.py $PKG/openai_server/tool_parsers/qwen3coder_tool_parser.py
md5sum $OVL/openai_server/fastllm_completion.py $PKG/openai_server/fastllm_completion.py
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
if [ "$RP" != "1" ]; then echo "PROD_NOT_READY — rollback: bash $W/scripts/rollback_r3.sh"; exit 5; fi

echo "--- PHASE5 新启动窗口关键行 ---"
tail -n +$((W0+1)) $PLOG | grep -aE "fastllm-experimental|context window limit|KV Cache Token limit|DFlash2\] enabled|DFlash2\] TP prepared|Traceback|Error" | head -14

echo "--- PHASE6 功能电池（post_switch_probe）---"
$VPY $W/post_switch_probe.py http://127.0.0.1:8080 $W/switch-r5-probe.json POST_R5 || echo PROBE_INCOMPLETE
echo "--- PHASE7 尾块≤64 回归（收敛式探针）---"
$VPY $W/r5_tail_probe2.py http://127.0.0.1:8080 $W/switch-r5-tail.json POST_R5_TAIL || echo TAIL_INCOMPLETE
echo "-- 日志指纹（自 PHASE4 起） --"
tail -n +$((W0+1)) $PLOG | grep -c 'long prefill cache seeded' | sed 's/^/seeded=/'
tail -n +$((W0+1)) $PLOG | grep -c 'draft cache is not aligned' | sed 's/^/desync=/'
tail -n +$((W0+1)) $PLOG | grep -o 'long prefill cache seeded: tokens=[0-9]*, chunk=[0-9]*' | tail -4

echo "SWITCH_DONE ready=$RP pkg=r5 so=$M" > $W/switch-r5.status
echo "===== SWITCH-R5 END $(date '+%F %T') ====="
