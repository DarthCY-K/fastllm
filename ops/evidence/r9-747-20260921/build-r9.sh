#!/bin/bash
# build-r9.sh — r9 candidate: r8 (6b9a1cca) + upstream 13 commits (2236e001) merged.
set -u
W=/home/ai-agent/builds/upgrade-test
NCCL_INC=/home/ai-agent/builds/fastllm-test-venv/lib/python3.13/site-packages/nvidia/nccl/include
cd $W
echo "BUILD_R9_START $(date "+%F %T")" > build-r9.status
if pgrep -f "make -C build-" > /dev/null; then echo "MAKE_ALREADY_RUNNING" >> build-r9.status; exit 3; fi
{ echo "--- r9 marker checks ---"
  printf "E1 fused-no-qkv: "; grep -c "no projected QKV is materialized" wt-r9/src/models/qwen3_5.cpp
  printf "E2 conv-skip: "; grep -c "single cache update) already done" wt-r9/src/models/qwen3_5.cpp
  printf "E3 output-skip: "; grep -c "must not re-apply" wt-r9/src/models/qwen3_5.cpp
  printf "E4 swapTag: "; grep -c "swapTag" wt-r9/src/models/qwen3_5.cpp
  printf "M1 nccl-timeout-env: "; grep -c "FASTLLM_NCCL_INIT_TIMEOUT_MS" wt-r9/src/devices/multicuda/fastllm-multicuda.cu
  printf "M2 watchdog: "; grep -c "FastllmNcclInitWatchdog" wt-r9/src/devices/multicuda/fastllm-multicuda.cu
  printf "M3 bf16-8row: "; grep -c "n == 8 && k <= 1024" wt-r9/src/devices/cuda/linear/fastllm-linear-bf16.cu
  printf "conflict markers: "; grep -rn "<<<<<<<" wt-r9/src wt-r9/include 2>/dev/null | wc -l
} >> build-r9.status 2>&1
export CPATH=$NCCL_INC
export LIBRARY_PATH=/home/ai-agent/builds/fastllm-link-deps
cmake -S wt-r9 -B build-r9 -DUSE_CUDA=ON -DUSE_NUMAS=ON -DUNIT_TEST=ON -DBUILD_CLI=OFF -DPY_API=OFF -DUSE_MMAP=OFF -DUSE_SENTENCEPIECE=OFF -DUSE_TFACC=OFF -DCUDA_ARCH=75 -DCMAKE_CUDA_COMPILER=/usr/local/cuda-12.8/bin/nvcc -DCMAKE_CUDA_HOST_COMPILER=/usr/bin/g++-13 -DCMAKE_CXX_COMPILER=/usr/bin/c++ > configure-r9.log 2>&1 || { echo "CMAKE_FAIL" >> build-r9.status; tail -30 configure-r9.log; exit 1; }
echo "CMAKE_OK $(date "+%T")" >> build-r9.status
make -C build-r9 -j96 fastllm_tools > build-r9.log 2>&1
RC=$?
if [ $RC -eq 0 ]; then echo BUILD_OK >> build-r9.status; else echo "BUILD_FAIL rc=$RC" >> build-r9.status; fi
ls -l build-r9/tools/ftllm/libfastllm_tools.so >> build-r9.status 2>&1
md5sum build-r9/tools/ftllm/libfastllm_tools.so >> build-r9.status 2>&1
echo "BUILD_R9_END $(date "+%F %T")" >> build-r9.status
