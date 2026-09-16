#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""apply_alloc_trace.py — 给 repo-r5 的 fastllm-cuda.cu 打「设备显存增长追踪」补丁。

目的：定位长会话期间 device0 显存持续增长（~6GB/20min）的来源。
机制：新增环境变量开关 FT_CUDA_ALLOC_TRACE（默认关），在真实 cudaMalloc
（池 miss）与失败点打印一行 [MTrace]，含 size / 设备 / 剩余显存 / 池统计。
仅当环境变量开启时才有输出与开销；关闭时与生产二进制行为一致。

新增文件内容：
  * 辅助函数块：FastllmCudaAllocTraceEnabled / MinBytes / StackEnabled /
    FastllmCudaTraceGrow（插在 FastllmCudaMallocImpl 之前）
  * big 路径 / small 路径：真实分配后（含 idle-retry 决议后）打点
  * FastllmCudaTryMallocBigBuffers（reserve）与 FastllmCudaMallocBigBuffer：打点

幂等：检测到 FT_CUDA_ALLOC_TRACE 已存在则跳过（exit 0）。
备份：首次打补丁时生成 fastllm-cuda.cu.bak-pre-alloctrace。
"""
import sys
from pathlib import Path

SRC = Path("/home/ai-agent/builds/upgrade-test/repo-r5/src/devices/cuda/fastllm-cuda.cu")
MARKER = "FT_CUDA_ALLOC_TRACE"

HELPERS = r'''
// ============================================================================
// FT_CUDA_ALLOC_TRACE — device-memory growth tracer (default off).
//   FT_CUDA_ALLOC_TRACE=1        enable tracing
//   FT_CUDA_ALLOC_TRACE_MIN_MB=N only trace allocations >= N MB (default 1)
//   FT_CUDA_ALLOC_TRACE_STACK=1  also print a short caller stack per event
// One [MTrace] line per real device allocation (pool miss) or failure, plus
// pool totals at that moment. Env is read once on first use; with the flag
// unset there is no extra output and no extra device call.
// ============================================================================
static bool FastllmCudaAllocTraceEnabled() {
    static int v = -1;
    if (v < 0) {
        const char *e = getenv("FT_CUDA_ALLOC_TRACE");
        v = (e != nullptr && atoi(e) != 0) ? 1 : 0;
    }
    return v != 0;
}

static bool FastllmCudaAllocTraceStackEnabled() {
    static int v = -1;
    if (v < 0) {
        const char *e = getenv("FT_CUDA_ALLOC_TRACE_STACK");
        v = (e != nullptr && atoi(e) != 0) ? 1 : 0;
    }
    return v != 0;
}

static size_t FastllmCudaAllocTraceMinBytes() {
    static size_t v = 0;
    if (v == 0) {
        const char *e = getenv("FT_CUDA_ALLOC_TRACE_MIN_MB");
        long long mb = (e != nullptr) ? atoll(e) : 1;
        if (mb <= 0) {
            mb = 1;
        }
        v = (size_t)mb * 1024ULL * 1024ULL;
    }
    return v;
}

static std::atomic<long long> fastllmCudaAllocTraceLines(0);
static const long long FASTLLM_CUDA_ALLOC_TRACE_MAX_LINES = 20000;

// 必须在持有对应设备池锁时调用（view 可为 nullptr，则省略池统计）。
static void FastllmCudaTraceGrow(
        int id, size_t size, const char *phase,
        const FastllmCudaMemPoolView *view, cudaError_t state) {
    if (!FastllmCudaAllocTraceEnabled() ||
        size < FastllmCudaAllocTraceMinBytes()) {
        return;
    }
    long long n = fastllmCudaAllocTraceLines.fetch_add(
        1, std::memory_order_relaxed);
    if (n >= FASTLLM_CUDA_ALLOC_TRACE_MAX_LINES) {
        if (n == FASTLLM_CUDA_ALLOC_TRACE_MAX_LINES) {
            fprintf(stderr, "[MTrace] line cap reached; tracing muted.\n");
            fflush(stderr);
        }
        return;
    }
    size_t freeMem = 0, totalMem = 0;
    cudaMemGetInfo(&freeMem, &totalMem);
    double bigTotal = 0, bigBusy = 0, smallTotal = 0, smallIdle = 0;
    if (view != nullptr && view->bigBuffers != nullptr &&
        view->smallBuffers != nullptr) {
        for (auto &b : *view->bigBuffers) {
            bigTotal += (double)b.size;
            if (b.busy) {
                bigBusy += (double)b.size;
            }
        }
        for (auto &b : *view->smallBuffers) {
            smallTotal += (double)b.size;
            if (!b.busy) {
                smallIdle += (double)b.size;
            }
        }
    }
    fprintf(stderr,
            "[MTrace] %s dev=%d size=%.1fMB free=%.0fMB big=%.0f/%.0fMB "
            "small=%.0f/%.0fMB idle state=%d\n",
            phase, id, (double)size / 1048576.0, (double)freeMem / 1048576.0,
            bigBusy / 1048576.0, bigTotal / 1048576.0,
            smallIdle / 1048576.0, smallTotal / 1048576.0, (int)state);
    fflush(stderr);
    if (FastllmCudaAllocTraceStackEnabled()) {
#if defined(__linux__) || defined(__APPLE__)
        void *frames[24];
        int numFrames = backtrace(frames, 24);
        char **symbols = backtrace_symbols(frames, numFrames);
        if (symbols != nullptr) {
            int skip = 2;
            int end = std::min(numFrames, skip + 12);
            for (int i = skip; i < end; i++) {
                fprintf(stderr, "[MTrace]   #%d %s\n", i - skip, symbols[i]);
            }
            free(symbols);
        }
#endif
    }
}

'''

BIG_OLD = """        state = FastllmCudaCheckedMalloc(&ret, size, __FILE__, __LINE__);
        if (state == cudaErrorMemoryAllocation &&
            FastllmCudaRetryMallocAfterReleasingIdle(
                size, &ret, id, __FILE__, __LINE__, &state)) {
            state = cudaSuccess;
        }
"""
BIG_NEW = BIG_OLD + """        FastllmCudaTraceGrow(id, size,
                             cudaSuccess == state ? "big-grow" : "big-FAIL",
                             &view, state);
"""

SMALL_OLD = """    state = FastllmCudaCheckedMalloc(&ret, size, __FILE__, __LINE__);
    if (state == cudaErrorMemoryAllocation &&
        FastllmCudaRetryMallocAfterReleasingIdle(
            size, &ret, id, __FILE__, __LINE__, &state)) {
        state = cudaSuccess;
    }
"""
SMALL_NEW = SMALL_OLD + """    FastllmCudaTraceGrow(id, size,
                         cudaSuccess == state ? "small-grow" : "small-FAIL",
                         &view, state);
"""

RESERVE_OLD = """            break;
        }
        bigBuffers.push_back(CudaMemoryBuffer(ret, size, false));
    }
    return allocated;
"""
RESERVE_NEW = """            break;
        }
        bigBuffers.push_back(CudaMemoryBuffer(ret, size, false));
        FastllmCudaTraceGrow(id, size, "reserve", &view, cudaSuccess);
    }
    return allocated;
"""

BIGBUF_OLD = """        return;
    }
    bigBuffers.push_back(CudaMemoryBuffer(ret, size, false));
}
"""
BIGBUF_NEW = """        return;
    }
    bigBuffers.push_back(CudaMemoryBuffer(ret, size, false));
    FastllmCudaTraceGrow(id, size, "bigbuf", &view, cudaSuccess);
}
"""

IMPL_ANCHOR = """static void *FastllmCudaMallocImpl(
        size_t size, FastllmCudaTryMallocResult *tryResult) {"""


def patch_once(text, old, new, label):
    n = text.count(old)
    if n != 1:
        print(f"ASSERT_FAIL {label}: expected 1 occurrence, found {n}", flush=True)
        sys.exit(2)
    print(f"OK {label}: 1 occurrence -> patched", flush=True)
    return text.replace(old, new, 1)


def main():
    if not SRC.exists():
        print(f"SRC_MISSING {SRC}", flush=True)
        sys.exit(2)
    text = SRC.read_text(encoding="utf-8")

    if MARKER in text:
        print("ALREADY_PATCHED", flush=True)
        sys.exit(0)

    assert text.count(IMPL_ANCHOR) == 1, "IMPL_ANCHOR not unique"

    # 1) helpers before the malloc impl
    text = patch_once(text, IMPL_ANCHOR, HELPERS + IMPL_ANCHOR, "helpers")
    # 2) big path
    text = patch_once(text, BIG_OLD, BIG_NEW, "big-path")
    # 3) small path
    text = patch_once(text, SMALL_OLD, SMALL_NEW, "small-path")
    # 4) reserve path
    text = patch_once(text, RESERVE_OLD, RESERVE_NEW, "reserve-path")
    # 5) big-buffer reserve path
    text = patch_once(text, BIGBUF_OLD, BIGBUF_NEW, "bigbuf-path")

    backup = SRC.with_name(SRC.name + ".bak-pre-alloctrace")
    if not backup.exists():
        backup.write_text(SRC.read_text(encoding="utf-8"), encoding="utf-8")
        print(f"BACKUP {backup}", flush=True)
    SRC.write_text(text, encoding="utf-8")
    print("PATCH_APPLIED", flush=True)


if __name__ == "__main__":
    main()
