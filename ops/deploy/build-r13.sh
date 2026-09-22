#!/bin/bash
# build-r13.sh — r13 candidate: r12 线（d50955ce: r12+gcfix+export 批量）+ 上游 82ebf072 10 提交
# 关注项: CUDA Graph 池/临时内存修复、张量视图设备归属、TrimBigBuffer/RetainCudaWorkspace 基建、NCCL 提交会合自旋
set -u
W=/home/ai-agent/builds/upgrade-test
NCCL_INC=/home/ai-agent/builds/fastllm-test-venv/lib/python3.13/site-packages/nvidia/nccl/include
cd $W
S=$W/build-r13.status
echo "BUILD_R13_START $(date '+%F %T')" > $S
if pgrep -f "make -C build-r13" > /dev/null; then echo "MAKE_ALREADY_RUNNING" >> $S; exit 3; fi
{
  echo "--- r13 marker checks ---"
  printf "conflict markers: ";    grep -rn "<<<<<<<" wt-r13/src wt-r13/include 2>/dev/null | wc -l
  printf "G1 TrimBigBuffer def: ";     grep -c "void FastllmCudaTrimBigBuffer" wt-r13/src/devices/cuda/fastllm-cuda.cu
  printf "G2 Expansion uses Trim: ";   grep -c "FastllmCudaTrimBigBuffer();" wt-r13/src/fastllm.cpp
  printf "G3 view dataDeviceIds: ";    grep -c "dataDeviceIds = ori.dataDeviceIds" wt-r13/src/fastllm.cpp
  printf "G4 managed capture only: ";  grep -c "FastllmCudaGraphSetManagedCaptureOnly" wt-r13/src/devices/cuda/fastllm-cuda.cu
  printf "G5 host numa node: ";        grep -c "FastllmCudaGetHostNumaNode" wt-r13/src/devices/cuda/fastllm-cuda.cu
  printf "G6 rendezvous spin: ";       grep -c "completedEpoch" wt-r13/include/devices/multicuda/ncclsubmitrendezvous.h
  printf "G7 RetainCudaWorkspace: ";   grep -c "RetainCudaWorkspace" wt-r13/include/models/basellm.h
  printf "G8 graphpool test target: "; grep -c "cudaGraphPoolMissRegression" wt-r13/CMakeLists.txt
  printf "L1 pooltrim intact: ";       grep -c "void FastllmCudaTrimIdleBigBuffers" wt-r13/src/devices/cuda/fastllm-cuda.cu
  printf "L2 gcfix intact: ";          grep -c "BEGIN IMMEDIATE" wt-r13/src/utils/disk_prefix_cache.cpp
  printf "L3 export batch intact: ";   grep -c "BatchChunks" wt-r13/src/utils/disk_prefix_cache.cpp
  printf "L4 mmguard intact: ";        grep -c "FT_QWEN35_MM_RESTORE_GUARD" wt-r13/src/models/qwen3_5.cpp
  printf "L5 triton sm75 intact: ";    grep -c "chunk_gdn_prefill_v9" wt-r13/src/devices/cuda/cudadevice.cpp
} >> $S 2>&1
echo "--- overlay util.py 一致性核对（overlay-r12 vs d50955ce 版）---" >> $S
diff -q overlay-r12/ftllm/util.py <(git -C repo show d50955ce:tools/fastllm_pytools/util.py) >> $S 2>&1 \
  && echo "util_py_sync=IDENTICAL" >> $S || echo "util_py_sync=DIFFERS" >> $S
export CPATH=$NCCL_INC
export LIBRARY_PATH=/home/ai-agent/builds/fastllm-link-deps
cmake -S wt-r13 -B build-r13 -DUSE_CUDA=ON -DUSE_NUMAS=ON -DUNIT_TEST=ON -DBUILD_CLI=OFF -DPY_API=OFF -DUSE_MMAP=OFF -DUSE_SENTENCEPIECE=OFF -DUSE_TFACC=OFF -DCUDA_ARCH=75 -DCMAKE_CUDA_COMPILER=/usr/local/cuda-12.8/bin/nvcc -DCMAKE_CUDA_HOST_COMPILER=/usr/bin/g++-13 -DCMAKE_CXX_COMPILER=/usr/bin/c++ -DCMAKE_EXE_LINKER_FLAGS=-static-libstdc++ > configure-r13.log 2>&1 || { echo CMAKE_FAIL >> $S; tail -30 configure-r13.log; exit 1; }
grep -E "disk_prefix_cache|SQLite|OpenSSL" configure-r13.log | head -6 >> $S
echo "CMAKE_OK $(date '+%T')" >> $S
make -C build-r13 -j64 fastllm_tools > build-r13.log 2>&1
RC=$?
if [ $RC -ne 0 ]; then echo "BUILD_FAIL rc=$RC" >> $S; tail -40 build-r13.log; exit 1; fi
echo "BUILD_OK $(date '+%T')" >> $S
SO=$W/build-r13/tools/ftllm/libfastllm_tools.so
ls -l $SO >> $S; md5sum $SO >> $S
{
  printf "so sm75_mma: ";          strings -a $SO | grep -c sm75_mma
  printf "so gdn_v9: ";            strings -a $SO | grep -c chunk_gdn_prefill_v9
  printf "so cache_sql_prepare: "; strings -a $SO | grep -c cache_sql_prepare
  printf "so ALLOW_YARN: ";        strings -a $SO | grep -c FASTLLM_ALLOW_YARN_WITH_DFLASH
  printf "so TrimBigBuffer: ";     strings -a $SO | grep -c TrimBigBuffer
  printf "so RetainWs: ";          strings -a $SO | grep -c RetainCudaWorkspace
  printf "so HostNumaNode: ";      strings -a $SO | grep -c GetHostNumaNode
} >> $S 2>&1
echo "--- overlay-r13 组装（基座=overlay-r12=现役生产 overlay；同步 merged util.py）---" >> $S
rm -rf overlay-r13
cp -a overlay-r12 overlay-r13
cp $SO overlay-r13/ftllm/libfastllm_tools.so
cp wt-r13/tools/fastllm_pytools/util.py overlay-r13/ftllm/util.py
md5sum overlay-r13/ftllm/libfastllm_tools.so >> $S 2>&1
echo "--- 测试目标构建 ---" >> $S
make -C build-r13 -j32 reduce_batch_test numas_nvfp4_moe_test moe_expert_partition_test nvfp4Block32GemmRegression cudaGraphPoolMissRegression cuda_prefill_paths_test cuda_marlin_sm75_ldmatrix_test cuda_bf16_bias_multigpu_test cuda_paged_fragmented_attention_test > build-r13-tests.log 2>&1
echo "tests_build_rc=$?" >> $S
make -C build-r13 -j32 nvfp4_planar_test >> build-r13-tests.log 2>&1; echo "planar_build_rc=$?" >> $S
tail -4 build-r13-tests.log >> $S
echo "BUILD_R13_END $(date '+%F %T')" >> $S
cat $S
