#!/bin/bash
# NOTE: -DCMAKE_EXE_LINKER_FLAGS=-static-libstdc++ is required on this box: CUDA adds
#   -L/usr/lib/gcc/x86_64-linux-gnu/13 which holds a real gcc-13 libstdc++.so without
#   CXXABI_1.3.15; gcc-14-built test executables would otherwise fail with
#   undefined reference to __cxa_call_terminate. Engine .so link is unaffected.
# build-r9b.sh — r9b candidate: r9 + PR #747 merged (persistent prefix / text compat).
set -u
W=/home/ai-agent/builds/upgrade-test
NCCL_INC=/home/ai-agent/builds/fastllm-test-venv/lib/python3.13/site-packages/nvidia/nccl/include
cd $W
echo "BUILD_R9B_START $(date "+%F %T")" > build-r9b.status
if pgrep -f "make -C build-" > /dev/null; then echo "MAKE_ALREADY_RUNNING" >> build-r9b.status; exit 3; fi
{ echo "--- r9b marker checks ---"
  printf "E1: "; grep -c "no projected QKV is materialized" wt-r9b/src/models/qwen3_5.cpp
  printf "E4 swapTag: "; grep -c "swapTag" wt-r9b/src/models/qwen3_5.cpp
  printf "P1 text-compat (qwen3_5_text): "; grep -c "qwen3_5_text" wt-r9b/src/models/qwen3_5.cpp
  printf "P2 persistent inc: "; ls -la wt-r9b/src/models/qwen3_5_persistent.inc | wc -l
  printf "P3 persistentPrefixCache refs: "; grep -c "persistentPrefixCache" wt-r9b/src/models/qwen3_5.cpp
  printf "P4 lmcache_fs files: "; ls wt-r9b/third_party/lmcache_fs/fs/ | wc -l
  printf "conflict markers: "; grep -rn "<<<<<<<" wt-r9b/src wt-r9b/include 2>/dev/null | wc -l
} >> build-r9b.status 2>&1
export CPATH=$NCCL_INC
export LIBRARY_PATH=/home/ai-agent/builds/fastllm-link-deps
cmake -S wt-r9b -B build-r9b -DUSE_CUDA=ON -DUSE_NUMAS=ON -DUNIT_TEST=ON -DBUILD_CLI=OFF -DPY_API=OFF -DUSE_MMAP=OFF -DUSE_SENTENCEPIECE=OFF -DUSE_TFACC=OFF -DCUDA_ARCH=75 -DCMAKE_CUDA_COMPILER=/usr/local/cuda-12.8/bin/nvcc -DCMAKE_CUDA_HOST_COMPILER=/usr/bin/g++-13 -DCMAKE_CXX_COMPILER=/usr/bin/c++ -DCMAKE_EXE_LINKER_FLAGS=-static-libstdc++ > configure-r9b.log 2>&1 || { echo "CMAKE_FAIL" >> build-r9b.status; tail -30 configure-r9b.log; exit 1; }
grep -E "disk_prefix_cache|SQLite|OpenSSL" configure-r9b.log | head -6 >> build-r9b.status
echo "CMAKE_OK $(date "+%T")" >> build-r9b.status
make -C build-r9b -j96 fastllm_tools > build-r9b.log 2>&1
RC=$?
if [ $RC -eq 0 ]; then echo BUILD_OK >> build-r9b.status; else echo "BUILD_FAIL rc=$RC" >> build-r9b.status; fi
ls -l build-r9b/tools/ftllm/libfastllm_tools.so >> build-r9b.status 2>&1
md5sum build-r9b/tools/ftllm/libfastllm_tools.so >> build-r9b.status 2>&1
printf "P5 so has cache_sql_prepare: "; strings -a build-r9b/tools/ftllm/libfastllm_tools.so 2>/dev/null | grep -c cache_sql_prepare
echo "BUILD_R9B_END $(date "+%F %T")" >> build-r9b.status
