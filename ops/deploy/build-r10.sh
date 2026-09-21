#!/bin/bash
# build-r10.sh — r10 candidate: r9b（含 PR #747）+ 上游 7a369c9d 11 提交合并
set -u
W=/home/ai-agent/builds/upgrade-test
NCCL_INC=/home/ai-agent/builds/fastllm-test-venv/lib/python3.13/site-packages/nvidia/nccl/include
cd $W
echo "BUILD_R10_START $(date '+%F %T')" > build-r10.status
if pgrep -f "make -C build-" > /dev/null; then echo "MAKE_ALREADY_RUNNING" >> build-r10.status; exit 3; fi
{ echo "--- r10 marker checks ---"
  printf "conflict markers: "; grep -rn "<<<<<<<" wt-r10/src wt-r10/include 2>/dev/null | wc -l
  printf "E1: "; grep -c "no projected QKV is materialized" wt-r10/src/models/qwen3_5.cpp
  printf "P1 text-compat: "; grep -c "qwen3_5_text" wt-r10/src/models/qwen3_5.cpp
  printf "P2 persistent inc: "; ls -la wt-r10/src/models/qwen3_5_persistent.inc | wc -l
  printf "P3 persistentPrefixCache refs: "; grep -c "persistentPrefixCache" wt-r10/src/models/qwen3_5.cpp
  printf "N1 new enum: "; grep -c "NVFP4_BLOCK_16_E4M3_PACKED" wt-r10/include/fastllm.h
  printf "N2 compactScales: "; grep -c "compactScales" wt-r10/include/fastllm.h
  printf "N3 qwen4 fusion: "; grep -c "FullAttention" wt-r10/src/devices/cuda/models/qwen4-kernels.cu
} >> build-r10.status 2>&1
export CPATH=$NCCL_INC
export LIBRARY_PATH=/home/ai-agent/builds/fastllm-link-deps
cmake -S wt-r10 -B build-r10 -DUSE_CUDA=ON -DUSE_NUMAS=ON -DUNIT_TEST=ON -DBUILD_CLI=OFF -DPY_API=OFF -DUSE_MMAP=OFF -DUSE_SENTENCEPIECE=OFF -DUSE_TFACC=OFF -DCUDA_ARCH=75 -DCMAKE_CUDA_COMPILER=/usr/local/cuda-12.8/bin/nvcc -DCMAKE_CUDA_HOST_COMPILER=/usr/bin/g++-13 -DCMAKE_CXX_COMPILER=/usr/bin/c++ -DCMAKE_EXE_LINKER_FLAGS=-static-libstdc++ > configure-r10.log 2>&1 || { echo "CMAKE_FAIL" >> build-r10.status; tail -30 configure-r10.log; exit 1; }
grep -E "disk_prefix_cache|SQLite|OpenSSL" configure-r10.log | head -6 >> build-r10.status
echo "CMAKE_OK $(date '+%T')" >> build-r10.status
make -C build-r10 -j96 fastllm_tools > build-r10.log 2>&1
RC=$?
if [ $RC -ne 0 ]; then echo "BUILD_FAIL rc=$RC" >> build-r10.status; tail -40 build-r10.log; exit 1; fi
echo "BUILD_OK" >> build-r10.status
ls -l build-r10/tools/ftllm/libfastllm_tools.so >> build-r10.status 2>&1
md5sum build-r10/tools/ftllm/libfastllm_tools.so >> build-r10.status 2>&1
{ printf "P5 so cache_sql_prepare: "; strings -a build-r10/tools/ftllm/libfastllm_tools.so | grep -c cache_sql_prepare
  printf "P6 so ALLOW_YARN: "; strings -a build-r10/tools/ftllm/libfastllm_tools.so | grep -c FASTLLM_ALLOW_YARN_WITH_DFLASH
  printf "N4 so new e4m3 packed: "; strings -a build-r10/tools/ftllm/libfastllm_tools.so | grep -cE "E4M3_PACKED|compact" || true
} >> build-r10.status 2>&1
echo "--- overlay-r10 组装 ---" >> build-r10.status
rm -rf overlay-r10
cp -a overlay-r9b overlay-r10
cp build-r10/tools/ftllm/libfastllm_tools.so overlay-r10/ftllm/libfastllm_tools.so
md5sum overlay-r10/ftllm/libfastllm_tools.so >> build-r10.status 2>&1
echo "--- 上游新增 CPU 单测 ---" >> build-r10.status
make -C build-r10 -j32 nvfp4Block32GemmRegression test_reduce_batch test_numas_nvfp4_moe > build-r10-tests.log 2>&1
for t in nvfp4Block32GemmRegression test_reduce_batch test_numas_nvfp4_moe; do
  B=$(find build-r10 -name "$t" -type f 2>/dev/null | head -1)
  if [ -n "$B" ] && [ -x "$B" ]; then
    { echo "== $t =="; "$B" 2>&1 | tail -4; } >> build-r10.status 2>&1
  else
    echo "$t: NOT_BUILT_OR_SKIP" >> build-r10.status 2>&1
  fi
done
echo "BUILD_R10_END $(date '+%F %T')" >> build-r10.status
