#!/bin/bash
# switch_to_r12.sh — 部署 r12 到生产 venv（lazy-recover 线 + 上游 14f849af 4 提交）+ 暖机兜底
# 回滚：bash wt-r12/ops/deploy/rollback_r12.sh（恢复 ftllm.backup-20260922-pre-r12）
# 注：默认不启用 SM75 Triton（保持 md5 逐位口径）；启用需在 fastllm_prod_launch.py 加
#     FASTLLM_CUDA_TRITON=1 + FASTLLM_CUDA_TRITON_PYTHON=~/.venvs/fastllm-triton-sm75/bin/python
set -u
trap "" HUP
W=/home/ai-agent/builds/upgrade-test
V=/home/ai-agent/builds/fastllm-video-venv
PKG=$V/lib/python3.13/site-packages/ftllm
OVL=$W/overlay-r12/ftllm
BK=$V/lib/python3.13/site-packages/ftllm.backup-20260922-pre-r12
VPY=$V/bin/python
PLOG=/home/ai-agent/fastllm-video-repro/results/server-prod.service.log
SO_EXPECT=4fb02a30c1562e54438846e4c66f014c
PARSER_EXPECT=b253557592c542888568f44374a258df
exec > >(tee -a $W/switch-r12.log) 2>&1
echo "===== SWITCH-R12 START $(date '+%F %T') ====="

echo "--- PHASE0 preflight ---"
[ -f $OVL/libfastllm_tools.so ] || { echo NO_OVERLAY_SO; exit 2; }
M=$(md5sum $OVL/libfastllm_tools.so | cut -d' ' -f1); echo "overlay-r12 so md5=$M"
[ "$M" = "$SO_EXPECT" ] || { echo "SO_MD5_MISMATCH expect=$SO_EXPECT"; exit 2; }
for s in ALLOW_YARN_WITH_DFLASH selector_q proposal_q FASTLLM_QWEN35_FINAL_CHUNK_DECODE_MAX FASTLLM_PREFIX_CACHE_SNAPSHOT_INTERVAL_PAGES; do
  c=$(strings -a $OVL/libfastllm_tools.so | grep -c "$s"); echo "  gate $s=$c"
  [ "$c" -ge 1 ] || { echo "MISSING_GATE $s"; exit 2; }
done
for s in "idle big-buffer trim" FP8LinearAdd cache_sql_prepare FASTLLM_NCCL_INIT_TIMEOUT_MS "Prefix SSD" sm75_mma chunk_gdn_prefill_v9_fp16_state; do
  c=$(strings -a $OVL/libfastllm_tools.so | grep -c "$s"); echo "  marker $s=$c"
  [ "$c" -ge 1 ] || { echo "MISSING_MARKER $s"; exit 2; }
done
grep -q "default_effort" $OVL/openai_server/fastllm_completion.py || { echo NO_MEDIUM_FIX; exit 2; }
grep -q "_log_args" $OVL/server.py || { echo NO_REDACT_PATCH; exit 2; }
[ -f $OVL/persistent_prefix.py ] || { echo NO_PERSISTENT_PREFIX; exit 2; }
P=$(md5sum $OVL/openai_server/tool_parsers/qwen3coder_tool_parser.py | cut -d' ' -f1)
[ "$P" = "$PARSER_EXPECT" ] || { echo "PARSER_MD5_MISMATCH $P"; exit 2; }
echo "python 层标记 OK (default_effort + 脱敏 + persistent_prefix + 重复参数宽容 $P)"
for f in libnuma.so.1 libfastllm_tools-cpu.so; do
  if [ -f "$PKG/$f" ] && [ ! -f "$OVL/$f" ]; then cp -a "$PKG/$f" "$OVL/$f" && echo "  copied $f"; fi
done

echo "--- PHASE1 backup venv ftllm ---"
if [ ! -d $BK ]; then cp -a $PKG $BK && echo "backup done -> $BK"; else echo "backup exists -> $BK"; fi
du -sh $BK 2>/dev/null

echo "--- PHASE2 sync overlay-r12 -> venv ---"
$VPY $W/scripts/sync_tree.py $OVL $PKG || { echo SYNC_FAIL; exit 3; }

echo "--- PHASE3 verify venv ---"
md5sum $OVL/libfastllm_tools.so $PKG/libfastllm_tools.so
md5sum $OVL/openai_server/tool_parsers/qwen3coder_tool_parser.py $PKG/openai_server/tool_parsers/qwen3coder_tool_parser.py
md5sum $OVL/openai_server/fastllm_completion.py $PKG/openai_server/fastllm_completion.py
cmp -s $OVL/persistent_prefix.py $PKG/persistent_prefix.py && echo "persistent_prefix.py synced"
$VPY -c "import ftllm, ftllm.persistent_prefix; from ftllm.openai_server import fastllm_completion as fc; print('import ok:', ftllm.__file__)" || { echo IMPORT_FAIL; exit 4; }

echo "--- PHASE4 restart prod ---"
W0=$(wc -l < $PLOG 2>/dev/null || echo 0)
sudo systemctl restart fastllm-qwen38-tp4
RP=0
for i in $(seq 1 240); do
  code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8080/v1/models 2>/dev/null)
  if [ "$code" = "401" ] || [ "$code" = "200" ]; then RP=1; echo "PROD_READY after ~$((i*5))s"; break; fi
  sleep 5
done
if [ "$RP" != "1" ]; then echo "PROD_NOT_READY — 回滚：bash $W/wt-r12/ops/deploy/rollback_r12.sh"; exit 5; fi

echo "--- PHASE5 新启动窗口关键行 ---"
tail -n +$((W0+1)) $PLOG | grep -aE "fastllm-experimental|context window limit|KV Cache Token limit|TP prepared|Traceback" | head -14

echo "--- PHASE5.5 暖机兜底（吸收 SSD 首请求读取校验）$(date '+%T') ---"
bash $W/scripts/warmup_prod.sh 360

echo "--- PHASE6 功能回归 run1 ---"
$VPY $W/trial_probe2.py http://127.0.0.1:8080 $W/switch-r12-probe.json || echo PROBE_INCOMPLETE
echo "--- PHASE7 复跑 run2 + 错误扫描 ---"
$VPY $W/trial_probe2.py http://127.0.0.1:8080 $W/switch-r12-probe2.json || echo PROBE2_INCOMPLETE
echo "errors_since_restart=$(tail -n +$((W0+1)) $PLOG | grep -ac 'FastLLM Error')"
tail -n +$((W0+1)) $PLOG | grep -aE "FastLLM Error|Traceback" | head -5
grep -o 'pos_accept_rate=\[[^]]*\]' $PLOG | tail -2
echo "seeded=$(tail -n +$((W0+1)) $PLOG | grep -ac 'long prefill cache seeded')"
echo "desync=$(tail -n +$((W0+1)) $PLOG | grep -ac 'draft cache is not aligned')"
echo "store_size=$(du -sh /home/ai-agent/prefix_ssd_prod 2>/dev/null | cut -f1)"

echo "SWITCH_R12_DONE ready=$RP so=$M" > $W/switch-r12.status
cat $W/switch-r12.status
echo "===== SWITCH-R12 END $(date '+%F %T') ====="
