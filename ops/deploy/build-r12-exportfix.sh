#!/bin/bash
# build-r12-exportfix.sh — r12 前缀缓存「导出批量发布」修复候选构建（wt-r12 增量）
# 修复对象: src/utils/disk_prefix_cache.cpp（State/StoreBytes/Commit）
#   E1 State::Pending + FlushPending()：整批 fsync（日志合并）+ rename + 单事务登记
#   E2 StoreBytes：去掉逐分片 intent/rename/目录同步/事务，改入 pending
#   E3 Commit：先 FlushPending 再索引（不引用未落盘数据）
#   E4 引擎内计时打印 [Prefix SSD] export: ...
#   （G* 为上一轮 GC 单事务修复的回归标记，必须仍在）
set -u
W=/home/ai-agent/builds/upgrade-test
cd "$W" || exit 1
S="$W/build-r12-exportfix.status"
SO="$W/build-r12/tools/ftllm/libfastllm_tools.so"
{
  echo "BUILD_R12_EXPORTFIX_START $(date '+%F %T')"
  echo "== 标记自检 =="
  printf "conflict_markers(expect 0): "; grep -rn "<<<<<<<" wt-r12/src wt-r12/include 2>/dev/null | wc -l
  printf "E1_flush_pending: ";      grep -c "void FlushPending()" wt-r12/src/utils/disk_prefix_cache.cpp
  printf "E1_batch_consts: ";       grep -c "BatchChunks = 16" wt-r12/src/utils/disk_prefix_cache.cpp
  printf "E2_deferred_publish: ";   grep -c "Publish is deferred" wt-r12/src/utils/disk_prefix_cache.cpp
  printf "E2_perchunk_intent_gone: "; grep -c ":blob:" wt-r12/src/utils/disk_prefix_cache.cpp
  printf "E3_commit_flush: ";       grep -c "state->FlushPending();" wt-r12/src/utils/disk_prefix_cache.cpp
  printf "E4_export_print: ";       grep -c "export: chunks=" wt-r12/src/utils/disk_prefix_cache.cpp
  printf "G1_single_txn: ";         grep -c "BEGIN IMMEDIATE" wt-r12/src/utils/disk_prefix_cache.cpp
  printf "G3_lockfree_lookup: ";    grep -c "never queue behind" wt-r12/src/utils/disk_prefix_cache.cpp
  printf "G6_gc_evidence: ";        grep -c "gc: evicted=" wt-r12/src/utils/disk_prefix_cache.cpp
} > "$S" 2>&1

mkdir -p "$W/artifacts"
if [ -f "$SO" ]; then
  M0=$(md5sum "$SO" | cut -d' ' -f1)
  echo "build-r12_so_pre_md5=$M0" >> "$S"
  case "$M0" in
    6e131be595e50ab911047d63ba999211)
      cp -a "$SO" "$W/artifacts/libfastllm_tools-r12-gcfix-6e131be5.so"
      echo "stashed=artifacts/libfastllm_tools-r12-gcfix-6e131be5.so (现役 v2)" >> "$S";;
  esac
fi

echo "== incremental make (build-r12, j64) ==" >> "$S"
export LIBRARY_PATH=/home/ai-agent/builds/fastllm-link-deps
make -C build-r12 -j64 fastllm_tools > "$W/build-r12-exportfix.log" 2>&1
RC=$?
if [ $RC -ne 0 ]; then
  echo "BUILD_FAIL rc=$RC $(date '+%T')" >> "$S"
  tail -60 "$W/build-r12-exportfix.log"
  exit 1
fi
echo "BUILD_OK $(date '+%T')" >> "$S"
ls -l "$SO" >> "$S"
md5sum "$SO" >> "$S"
{
  printf "so_gc_print: ";      strings -a "$SO" | grep -c "gc: evicted="
  printf "so_export_print: ";  strings -a "$SO" | grep -c "export: chunks="
  printf "so_sm75_mma_hits: "; strings -a "$SO" | grep -c sm75_mma
  printf "so_gdn_v9_hits: ";   strings -a "$SO" | grep -c chunk_gdn_prefill_v9
  printf "so_cache_sql_prepare: "; strings -a "$SO" | grep -c cache_sql_prepare
} >> "$S" 2>&1

echo "== overlay-r12-exp 组装 ==" >> "$S"
rm -rf overlay-r12-exp
cp -a overlay-r12 overlay-r12-exp
cp "$SO" overlay-r12-exp/ftllm/libfastllm_tools.so
md5sum overlay-r12-exp/ftllm/libfastllm_tools.so overlay-r12/ftllm/libfastllm_tools.so >> "$S" 2>&1
echo "BUILD_R12_EXPORTFIX_END $(date '+%F %T')" >> "$S"
cat "$S"
