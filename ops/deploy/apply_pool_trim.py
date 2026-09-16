#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""apply_pool_trim.py — 主修补丁：请求结束回收空闲大块（device big 池不再无上限累积）。

背景（2026-09-16 取证）：长会话多模态负载下，多模态/DFlash 临时块尺寸不断变化，
空闲块沉在 CUDA big 池里既不重用也不回退设备 → device0 显存单调增长直至 OOM
（15:10 / 19:07 两次 ABORT 同源）。[MTrace]+调用栈已定位分配点（EncodeVisualItems、
AppendDFlashTargetHidden、EnsureDFlashRotary、ForwardSingleGPU CopyFrom、长预填大临时块）。

补丁内容：
  1) fastllm-cuda.cu：新增 FastllmCudaTrimIdleBigBuffers(minBytes) —
     释放 ≥minBytes 的空闲大块（busy/graphPins/受图保护的保留），打印一行汇总。
  2) fastllm-cuda.cuh：声明该函数。
  3) qwen3_5.cpp：新增两个 env 助手（默认开，FT_QWEN35_REQUEST_POOL_TRIM=0 关闭；
     阈值 FT_QWEN35_REQUEST_POOL_TRIM_MIN_MB 默认 32）；
     在请求结束（isEnding 清理）与 abort 清理处调用 trim。

幂等：检测到 FastllmCudaTrimIdleBigBuffers 已存在则跳过。
备份：分别生成 *.bak-pre-pooltrim。
"""
import sys
from pathlib import Path

R = Path("/home/ai-agent/builds/upgrade-test/repo-r5")
CU = R / "src/devices/cuda/fastllm-cuda.cu"
CUH = R / "include/devices/cuda/fastllm-cuda.cuh"
Q = R / "src/models/qwen3_5.cpp"

MARKER = "FastllmCudaTrimIdleBigBuffers"

TRIM_FUNC = r'''
// 请求结束回收：释放大小 >= minBytes 的空闲大块，保留小块热池复用。
// 长会话下多模态/DFlash 临时块尺寸不断变化，空闲块在 big 池里既不重用也不
// 回退设备，会让显存单调增长直至 OOM（2026-09-16 取证）。请求结束时调用本函数，
// 让空闲大块退回设备，显存回到基线。busy / graphPins / 图保护的块不释放。
void FastllmCudaTrimIdleBigBuffers(size_t minBytes) {
    if (fastllmCudaMallocDisabled.load(std::memory_order_relaxed)) {
        return;
    }
    int id = -1;
    cudaGetDevice(&id);
    std::vector<FastllmCudaMemPoolView> views = FastllmSnapshotCudaMemPoolViews();
    if (views.empty()) {
        return;
    }
    size_t releasedBytes = 0;
    int releasedBlocks = 0;
    cudaError_t state = cudaSuccess;
    // 逐设备各自加锁清理：cudaSetDevice/cudaFree 只在对应设备锁内进行。
    for (auto &view : views) {
        std::lock_guard<std::mutex> lock(*view.lock);
        state = cudaSetDevice(view.device);
        checkCudaErrors(
            "Error: CUDA error when switching device to trim idle big buffers!",
            state);
        auto &bigBuffers = *view.bigBuffers;
        std::vector <CudaMemoryBuffer> temp;
        for (int i = 0; i < bigBuffers.size(); i++) {
            auto &buffer = bigBuffers[i];
            if (!buffer.busy && buffer.graphPins == 0 &&
                buffer.size >= minBytes &&
                FastllmCudaBufferReadyForReuseLocked(buffer) &&
                !FastllmCudaGraphPoolPointerProtectedLocked(buffer.data)) {
                FastllmCudaDestroyReuseEventLocked(buffer);
                state = cudaFree(buffer.data);
                if (cudaSuccess == state) {
                    releasedBytes += buffer.size;
                    releasedBlocks++;
                    continue;
                }
                printf("Error: CUDA error when releasing idle big buffer on device %d!\n",
                       view.device);
                fflush(stdout);
                checkCudaErrors("", state);
            }
            temp.push_back(buffer);
        }
        bigBuffers.clear();
        bigBuffers = temp;
    }
    cudaSetDevice(id);
    if (releasedBlocks > 0) {
        printf("[Fastllm] idle big-buffer trim: released %d block(s), %.0f MB\n",
               releasedBlocks, (double)releasedBytes / 1048576.0);
        fflush(stdout);
    }
}

'''

CU_ANCHOR = "void FastllmCudaClearBigBuffer() {"

CUH_ANCHOR = """void FastllmCudaClearBigBuffer();
"""

CUH_NEW = """void FastllmCudaClearBigBuffer();
void FastllmCudaTrimIdleBigBuffers(size_t minBytes);
"""

Q_HELPERS_ANCHOR = """        static bool Qwen35MmcacheSeedEnabled() {
            static int v = -1;
            if (v < 0) {
                const char *e = getenv("FT_QWEN35_MM_CACHE_SEED");
                v = (e == nullptr || atoi(e) != 0) ? 1 : 0;
            }
            return v != 0;
        }
"""

Q_HELPERS_NEW = Q_HELPERS_ANCHOR + """
        // 请求结束回收（默认开，FT_QWEN35_REQUEST_POOL_TRIM=0 关闭）
        static bool Qwen35RequestPoolTrimEnabled() {
            static int v = -1;
            if (v < 0) {
                const char *e = getenv("FT_QWEN35_REQUEST_POOL_TRIM");
                v = (e == nullptr || atoi(e) != 0) ? 1 : 0;
            }
            return v != 0;
        }

        // 阈值：只释放 >= N MB 的空闲大块（默认 32，<=0 视为默认值）
        static size_t Qwen35RequestPoolTrimMinBytes() {
            static size_t v = 0;
            if (v == 0) {
                const char *e = getenv("FT_QWEN35_REQUEST_POOL_TRIM_MIN_MB");
                long long mb = (e != nullptr) ? atoll(e) : 32;
                if (mb <= 0) {
                    mb = 32;
                }
                v = (size_t)mb * 1024ULL * 1024ULL;
            }
            return v;
        }
"""

Q_END_OLD = """                if (ctx->isEnding) {
                    for (int i = 0; i < model->block_cnt && i < (int)ctx->pastKeyValues.size(); i++) {
                        releasePagedCachePages(ctx->pastKeyValues[i].first);
                        releasePagedCachePages(ctx->pastKeyValues[i].second);
                    }
                    eraseMtpCache(ctx);
                    continue;
                }
"""

Q_END_NEW = """                if (ctx->isEnding) {
                    for (int i = 0; i < model->block_cnt && i < (int)ctx->pastKeyValues.size(); i++) {
                        releasePagedCachePages(ctx->pastKeyValues[i].first);
                        releasePagedCachePages(ctx->pastKeyValues[i].second);
                    }
                    eraseMtpCache(ctx);
                    if (Qwen35RequestPoolTrimEnabled()) {
                        FastllmCudaTrimIdleBigBuffers(
                            Qwen35RequestPoolTrimMinBytes());
                    }
                    continue;
                }
"""

Q_ABORT_OLD = """            for (int handle : abortHandles) {
                model->RemoveResponseContext(handle);
            }
"""

Q_ABORT_NEW = """            for (int handle : abortHandles) {
                model->RemoveResponseContext(handle);
            }
            if (!abortHandles.empty() && Qwen35RequestPoolTrimEnabled()) {
                FastllmCudaTrimIdleBigBuffers(Qwen35RequestPoolTrimMinBytes());
            }
"""


def patch(path, old, new, label, backup=False):
    text = path.read_text(encoding="utf-8")
    n = text.count(old)
    if n != 1:
        print(f"ASSERT_FAIL {label}: expected 1 occurrence, found {n}", flush=True)
        sys.exit(2)
    if backup:
        bak = path.with_name(path.name + ".bak-pre-pooltrim")
        if not bak.exists():
            bak.write_text(text, encoding="utf-8")
            print(f"BACKUP {bak}", flush=True)
    path.write_text(text.replace(old, new, 1), encoding="utf-8")
    print(f"OK {label}", flush=True)


def main():
    for f in (CU, CUH, Q):
        if not f.exists():
            print(f"SRC_MISSING {f}", flush=True)
            sys.exit(2)
    if MARKER in CU.read_text(encoding="utf-8"):
        print("ALREADY_PATCHED", flush=True)
        sys.exit(0)

    patch(CU, CU_ANCHOR, TRIM_FUNC.lstrip("\n") + CU_ANCHOR, "cuda-trim-func")
    patch(CUH, CUH_ANCHOR, CUH_NEW, "cuh-decl")
    patch(Q, Q_HELPERS_ANCHOR, Q_HELPERS_NEW, "qwen-helpers")
    patch(Q, Q_END_OLD, Q_END_NEW, "qwen-end-trim")
    patch(Q, Q_ABORT_OLD, Q_ABORT_NEW, "qwen-abort-trim")
    print("PATCH_APPLIED", flush=True)


if __name__ == "__main__":
    main()
