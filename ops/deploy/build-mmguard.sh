#!/bin/bash
# build-mmguard.sh — 构建「视觉复原保护」版本（2026-09-17）
#   源 = repo-r5（现行生产源码）+ apply_mm_restore_guard.py
#   产出 = build-mmguard/tools/ftllm/libfastllm_tools.so
# 部署 = scripts/switch_to_mmguard.sh；回滚 = scripts/rollback_mmguard.sh
set -u
W=/home/ai-agent/builds/upgrade-test
NCCL_INC=/home/ai-agent/builds/fastllm-test-venv/lib/python3.13/site-packages/nvidia/nccl/include
cd $W
echo "BUILD_MMGUARD_START $(date '+%F %T')" > build-mmguard.status

if pgrep -f "make -[j]" > /dev/null; then echo "MAKE_ALREADY_RUNNING" >> build-mmguard.status; exit 3; fi

python3 apply_mm_restore_guard.py >> build-mmguard.status 2>&1 || { echo "PATCH_FAIL" >> build-mmguard.status; exit 1; }

rm -rf build-mmguard
export CPATH=$NCCL_INC
export LIBRARY_PATH=/home/ai-agent/builds/fastllm-link-deps
cmake -S repo-r5 -B build-mmguard -DUSE_CUDA=ON -DUSE_NUMAS=ON -DUNIT_TEST=ON -DBUILD_CLI=OFF -DPY_API=OFF -DUSE_MMAP=OFF -DUSE_SENTENCEPIECE=OFF -DUSE_TFACC=OFF -DCUDA_ARCH=75 -DCMAKE_CUDA_COMPILER=/usr/local/cuda-12.8/bin/nvcc -DCMAKE_CUDA_HOST_COMPILER=/usr/bin/g++-13 -DCMAKE_CXX_COMPILER=/usr/bin/c++ > configure-mmguard.log 2>&1 \
  || { echo "CMAKE_FAIL" >> build-mmguard.status; tail -30 configure-mmguard.log; exit 1; }
echo "CMAKE_OK $(date '+%T')" >> build-mmguard.status

make -C build-mmguard -j96 fastllm_tools > build-mmguard.log 2>&1
RC=$?
if [ $RC -eq 0 ]; then echo BUILD_OK >> build-mmguard.status; else echo "BUILD_FAIL rc=$RC" >> build-mmguard.status; fi
ls -l build-mmguard/tools/ftllm/libfastllm_tools.so >> build-mmguard.status 2>&1
md5sum build-mmguard/tools/ftllm/libfastllm_tools.so >> build-mmguard.status 2>&1
{
  printf "so marker guard-env: "; strings -a build-mmguard/tools/ftllm/libfastllm_tools.so | grep -c "FT_QWEN35_MM_RESTORE_GUARD"
  printf "so marker guard-log: "; strings -a build-mmguard/tools/ftllm/libfastllm_tools.so | grep -c "prefix restore skipped"
  printf "carry pooltrim: "; strings -a build-mmguard/tools/ftllm/libfastllm_tools.so | grep -c "idle big-buffer trim"
  printf "carry mmcache: "; strings -a build-mmguard/tools/ftllm/libfastllm_tools.so | grep -c "MMSeed"
  printf "carry yarn gate: "; strings -a build-mmguard/tools/ftllm/libfastllm_tools.so | grep -c ALLOW_YARN_WITH_DFLASH
} >> build-mmguard.status 2>&1
echo "BUILD_MMGUARD_END $(date '+%F %T')" >> build-mmguard.status
cat build-mmguard.status
