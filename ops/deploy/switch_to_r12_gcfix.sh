#!/bin/bash
# switch_to_r12_gcfix.sh — 部署 gcfix（SSD GC/查表门闩修复）到生产 venv + 暖机 + 回归
# 回滚: bash wt-r12/ops/deploy/rollback_r12_gcfix.sh （恢复 ftllm.backup-20260922-pre-gcfix）
# 变更面: 仅 libfastllm_tools.so（overlay 其余文件与 overlay-r12 逐字节一致）
set -u
trap "" HUP
W=/home/ai-agent/builds/upgrade-test
V=/home/ai-agent/builds/fastllm-video-venv
PKG=$V/lib/python3.13/site-packages/ftllm
OVL=$W/overlay-r12-gcfix/ftllm
OVL0=$W/overlay-r12/ftllm
BK=$V/lib/python3.13/site-packages/ftllm.backup-20260922-pre-gcfix
VPY=$V/bin/python
PLOG=/home/ai-agent/fastllm-video-repro/results/server-prod.service.log
SO_EXPECT=6e131be595e50ab911047d63ba999211
SO_ROLLBACK=4fb02a30c1562e54438846e4c66f014c
PARSER_EXPECT=b253557592c542888568f44374a258df
exec > >(tee -a $W/switch-gcfix.log) 2>&1
echo "===== SWITCH-GCFIX START $(date '+%F %T') ====="

echo "--- PHASE0 preflight ---"
[ -f $OVL/libfastllm_tools.so ] || { echo NO_OVERLAY_SO; exit 2; }
M=$(md5sum $OVL/libfastllm_tools.so | cut -d' ' -f1); echo "overlay-r12-gcfix so md5=$M"
[ "$M" = "$SO_EXPECT" ] || { echo "SO_MD5_MISMATCH expect=$SO_EXPECT"; exit 2; }
for s in ALLOW_YARN_WITH_DFLASH selector_q proposal_q FASTLLM_QWEN35_FINAL_CHUNK_DECODE_MAX FASTLLM_PREFIX_CACHE_SNAPSHOT_INTERVAL_PAGES; do
  c=$(strings -a $OVL/libfastllm_tools.so | grep -c "$s"); echo "  gate $s=$c"
  [ "$c" -ge 1 ] || { echo "MISSING_GATE $s"; exit 2; }
done
for s in "idle big-buffer trim" FP8LinearAdd cache_sql_prepare FASTLLM_NCCL_INIT_TIMEOUT_MS "Prefix SSD" sm75_mma chunk_gdn_prefill_v9_fp16_state "gc: evicted="; do
  c=$(strings -a $OVL/libfastllm_tools.so | grep -c "$s"); echo "  marker $s=$c"
  [ "$c" -ge 1 ] || { echo "MISSING_MARKER $s"; exit 2; }
done
echo "--- 差异面自检：overlay 其余文件应与 overlay-r12 完全一致（只允许 .so 不同）---"
DIFF=$(diff -rq $OVL0 $OVL | grep -v "libfastllm_tools.so")
if [ -n "$DIFF" ]; then echo "UNEXPECTED_DIFF:"; echo "$DIFF" | head -20; exit 2; fi
echo "diff ok（除 .so 外零差异）"
grep -q "default_effort" $OVL/openai_server/fastllm_completion.py || { echo NO_MEDIUM_FIX; exit 2; }
grep -q "_log_args" $OVL/server.py || { echo NO_REDACT_PATCH; exit 2; }
[ -f $OVL/persistent_prefix.py ] || { echo NO_PERSISTENT_PREFIX; exit 2; }
P=$(md5sum $OVL/openai_server/tool_parsers/qwen3coder_tool_parser.py | cut -d' ' -f1)
[ "$P" = "$PARSER_EXPECT" ] || { echo "PARSER_MD5_MISMATCH $P"; exit 2; }
for f in libnuma.so.1 libfastllm_tools-cpu.so; do
  if [ -f "$PKG/$f" ] && [ ! -f "$OVL/$f" ]; then cp -a "$PKG/$f" "$OVL/$f" && echo "  copied $f"; fi
done

echo "--- PHASE1 backup venv ftllm -> $BK ---"
if [ ! -d $BK ]; then cp -a $PKG $BK && echo "backup done"; else echo "backup exists"; fi
du -sh $BK 2>/dev/null

echo "--- PHASE2 sync overlay-r12-gcfix -> venv ---"
$VPY $W/scripts/sync_tree.py $OVL $PKG || { echo SYNC_FAIL; exit 3; }

echo "--- PHASE3 verify venv ---"
md5sum $OVL/libfastllm_tools.so $PKG/libfastllm_tools.so
VMD5=$(md5sum $PKG/libfastllm_tools.so | cut -d' ' -f1)
[ "$VMD5" = "$SO_EXPECT" ] || { echo "VENV_SO_MISMATCH $VMD5"; exit 3; }
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
if [ "$RP" != "1" ]; then echo "PROD_NOT_READY — 回滚：bash $W/wt-r12/ops/deploy/rollback_r12_gcfix.sh"; exit 5; fi

echo "--- PHASE5 新启动窗口关键行 ---"
tail -n +$((W0+1)) $PLOG | grep -aE "fastllm-experimental|context window limit|KV Cache Token limit|TP prepared|Prefix SSD|Traceback" | head -14

echo "--- PHASE5.5 暖机兜底 $(date '+%T') ---"
bash $W/scripts/warmup_prod.sh 360

echo "--- PHASE6 功能回归 run1 ---"
$VPY $W/trial_probe2.py http://127.0.0.1:8080 $W/switch-gcfix-probe.json || echo PROBE_INCOMPLETE
echo "--- PHASE7 复跑 run2 + 错误扫描 ---"
$VPY $W/trial_probe2.py http://127.0.0.1:8080 $W/switch-gcfix-probe2.json || echo PROBE2_INCOMPLETE
echo "errors_since_restart=$(tail -n +$((W0+1)) $PLOG | grep -ac 'FastLLM Error')"
tail -n +$((W0+1)) $PLOG | grep -aE "FastLLM Error|Traceback" | head -5
grep -o 'pos_accept_rate=\[[^]]*\]' $PLOG | tail -2
echo "seeded=$(tail -n +$((W0+1)) $PLOG | grep -ac 'long prefill cache seeded')"
echo "desync=$(tail -n +$((W0+1)) $PLOG | grep -ac 'draft cache is not aligned')"
echo "store_size=$(du -sh /home/ai-agent/prefix_ssd_prod 2>/dev/null | cut -f1)"

echo "SWITCH_GCFIX_DONE ready=$RP so=$M (rollback=$SO_ROLLBACK)" > $W/switch-gcfix.status
cat $W/switch-gcfix.status
echo "===== SWITCH-GCFIX END $(date '+%F %T') ====="
