#!/bin/bash
# build-r11.sh — r11 candidate: r10 线（r9b+#747+上游11提交+API key 加固）+ 上游 3f1dcc42 4 提交
set -u
W=/home/ai-agent/builds/upgrade-test
NCCL_INC=/home/ai-agent/builds/fastllm-test-venv/lib/python3.13/site-packages/nvidia/nccl/include
cd $W
echo "BUILD_R11_START $(date '+%F %T')" > build-r11.status
if pgrep -f "make -C build-" > /dev/null; then echo "MAKE_ALREADY_RUNNING" >> build-r11.status; exit 3; fi
{ echo "--- r11 marker checks ---"
  printf "conflict markers: "; grep -rn "<<<<<<<" wt-r11/src wt-r11/include 2>/dev/null | wc -l
  printf "E1: "; grep -c "no projected QKV is materialized" wt-r11/src/models/qwen3_5.cpp
  printf "P1 text-compat: "; grep -c "qwen3_5_text" wt-r11/src/models/qwen3_5.cpp
  printf "P2 persistent inc: "; ls -la wt-r11/src/models/qwen3_5_persistent.inc | wc -l
  printf "P3 persistentPrefixCache refs: "; grep -c "persistentPrefixCache" wt-r11/src/models/qwen3_5.cpp
  printf "N1 new enum: "; grep -c "NVFP4_BLOCK_16_E4M3_PACKED" wt-r11/include/fastllm.h
  printf "N2 compactScales: "; grep -c "compactScales" wt-r11/include/fastllm.h
  printf "N3 qwen4 fusion: "; grep -c "FullAttention" wt-r11/src/devices/cuda/models/qwen4-kernels.cu
  printf "N5 numas partition hdr: "; ls wt-r11/src/devices/numas/moeexpertpartition.h | wc -l
} >> build-r11.status 2>&1
export CPATH=$NCCL_INC
export LIBRARY_PATH=/home/ai-agent/builds/fastllm-link-deps
cmake -S wt-r11 -B build-r11 -DUSE_CUDA=ON -DUSE_NUMAS=ON -DUNIT_TEST=ON -DBUILD_CLI=OFF -DPY_API=OFF -DUSE_MMAP=OFF -DUSE_SENTENCEPIECE=OFF -DUSE_TFACC=OFF -DCUDA_ARCH=75 -DCMAKE_CUDA_COMPILER=/usr/local/cuda-12.8/bin/nvcc -DCMAKE_CUDA_HOST_COMPILER=/usr/bin/g++-13 -DCMAKE_CXX_COMPILER=/usr/bin/c++ -DCMAKE_EXE_LINKER_FLAGS=-static-libstdc++ > configure-r11.log 2>&1 || { echo "CMAKE_FAIL" >> build-r11.status; tail -30 configure-r11.log; exit 1; }
grep -E "disk_prefix_cache|SQLite|OpenSSL" configure-r11.log | head -6 >> build-r11.status
echo "CMAKE_OK $(date '+%T')" >> build-r11.status
make -C build-r11 -j96 fastllm_tools > build-r11.log 2>&1
RC=$?
if [ $RC -ne 0 ]; then echo "BUILD_FAIL rc=$RC" >> build-r11.status; tail -40 build-r11.log; exit 1; fi
echo "BUILD_OK" >> build-r11.status
ls -l build-r11/tools/ftllm/libfastllm_tools.so >> build-r11.status 2>&1
md5sum build-r11/tools/ftllm/libfastllm_tools.so >> build-r11.status 2>&1
{ printf "P5 so cache_sql_prepare: "; strings -a build-r11/tools/ftllm/libfastllm_tools.so | grep -c cache_sql_prepare
  printf "P6 so ALLOW_YARN: "; strings -a build-r11/tools/ftllm/libfastllm_tools.so | grep -c FASTLLM_ALLOW_YARN_WITH_DFLASH
  printf "N4 so new e4m3 packed: "; strings -a build-r11/tools/ftllm/libfastllm_tools.so | grep -cE "E4M3_PACKED|compact" || true
} >> build-r11.status 2>&1
echo "--- overlay-r11 组装 ---" >> build-r11.status
rm -rf overlay-r11
cp -a overlay-r10 overlay-r11
cp build-r11/tools/ftllm/libfastllm_tools.so overlay-r11/ftllm/libfastllm_tools.so
md5sum overlay-r11/ftllm/libfastllm_tools.so >> build-r11.status 2>&1
echo "--- 上游新增 CPU 单测 ---" >> build-r11.status
make -C build-r11 -j32 -k nvfp4Block32GemmRegression test_reduce_batch test_numas_nvfp4_moe test_moe_expert_partition > build-r11-tests.log 2>&1
for t in nvfp4Block32GemmRegression test_reduce_batch test_numas_nvfp4_moe test_moe_expert_partition; do
  B=$(find build-r11 -name "$t" -type f 2>/dev/null | head -1)
  if [ -n "$B" ] && [ -x "$B" ]; then
    { echo "== $t =="; "$B" 2>&1 | tail -4; } >> build-r11.status 2>&1
  else
    echo "$t: NOT_BUILT_OR_SKIP" >> build-r11.status 2>&1
  fi
done
echo "BUILD_R11_END $(date '+%F %T')" >> build-r11.status
