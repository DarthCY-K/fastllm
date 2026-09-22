#!/bin/bash
# build-r12-gcfix.sh — r12 前缀缓存「暖恢复门闩」修复的候选构建（wt-r12 增量）
# 修复对象: src/utils/disk_prefix_cache.cpp
#   F1 Maintain(): 批量 WAL checkpoint/目录同步（原每次驱逐都 fsync）
#   F2 Maintain(): 孤儿对象按本轮 checkpoint 的引用精确回收（原每次全表扫描）
#   F3 ListCheckpoints(): 读路径无锁 WAL 快照读（原拿 .metadata 排他锁）
#   F4 ListCheckpoints(): 不再因在飞 intent 落全树 Scan；写侧 BeginWrite 仍强制
set -u
W=/home/ai-agent/builds/upgrade-test
cd "$W" || exit 1
S="$W/build-r12-gcfix.status"
SO="$W/build-r12/tools/ftllm/libfastllm_tools.so"
{
  echo "BUILD_R12_GCFIX_START $(date '+%F %T')"
  echo "== 标记自检 (期望: F1..F6=1, 冲突=0) =="
  printf "conflict_markers(expect 0): "; grep -rn "<<<<<<<" wt-r12/src wt-r12/include 2>/dev/null | wc -l
  printf "F1_single_txn: ";        grep -c "BEGIN IMMEDIATE" wt-r12/src/utils/disk_prefix_cache.cpp
  printf "F2_scoped_sweep: ";        grep -c "SELECT 1 FROM refs WHERE hash=? LIMIT 1" wt-r12/src/utils/disk_prefix_cache.cpp
  printf "F3_lockfree_lookup: ";     grep -c "never queue behind" wt-r12/src/utils/disk_prefix_cache.cpp
  printf "F4_write_intent_kept: ";   grep -c "cache_index_needs_rebuild" wt-r12/src/utils/disk_prefix_cache.cpp
  printf "F5_batched_syncs: ";       grep -c "touched.insert(id)" wt-r12/src/utils/disk_prefix_cache.cpp
  printf "F6_gc_evidence: ";         grep -c "gc: evicted=" wt-r12/src/utils/disk_prefix_cache.cpp
} > "$S" 2>&1

mkdir -p "$W/artifacts"
if [ -f "$SO" ]; then
  M0=$(md5sum "$SO" | cut -d' ' -f1)
  echo "build-r12_so_pre_md5=$M0" >> "$S"
  case "$M0" in
    4fb02a30c1562e54438846e4c66f014c)
      cp -a "$SO" "$W/artifacts/libfastllm_tools-r12-4fb02a30.so"
      echo "stashed=artifacts/libfastllm_tools-r12-4fb02a30.so (现役 r12)" >> "$S";;
    f7d1390b4926e22dc1562734e3b221aa)
      cp -a "$SO" "$W/artifacts/libfastllm_tools-r12-gcfix-v1-f7d1390b.so"
      echo "stashed=artifacts/libfastllm_tools-r12-gcfix-v1-f7d1390b.so (v1 未生效版)" >> "$S";;
  esac
fi

echo "== incremental make (build-r12, j64) ==" >> "$S"
export LIBRARY_PATH=/home/ai-agent/builds/fastllm-link-deps
make -C build-r12 -j64 fastllm_tools > "$W/build-r12-gcfix.log" 2>&1
RC=$?
if [ $RC -ne 0 ]; then
  echo "BUILD_FAIL rc=$RC $(date '+%T')" >> "$S"
  tail -60 "$W/build-r12-gcfix.log"
  exit 1
fi
echo "BUILD_OK $(date '+%T')" >> "$S"
ls -l "$SO" >> "$S"
md5sum "$SO" >> "$S"
{
  printf "so_sm75_mma_hits: ";   strings -a "$SO" | grep -c sm75_mma
  printf "so_gdn_v9_hits: ";     strings -a "$SO" | grep -c chunk_gdn_prefill_v9
  printf "so_cache_sql_prepare: "; strings -a "$SO" | grep -c cache_sql_prepare
} >> "$S" 2>&1

echo "== overlay-r12-gcfix 组装 ==" >> "$S"
rm -rf overlay-r12-gcfix
cp -a overlay-r12 overlay-r12-gcfix
cp "$SO" overlay-r12-gcfix/ftllm/libfastllm_tools.so
md5sum overlay-r12-gcfix/ftllm/libfastllm_tools.so overlay-r12/ftllm/libfastllm_tools.so >> "$S" 2>&1
echo "BUILD_R12_GCFIX_END $(date '+%F %T')" >> "$S"
cat "$S"
