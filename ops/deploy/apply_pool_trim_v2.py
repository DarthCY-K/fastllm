#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""apply_pool_trim_v2.py — 主修 v2：默认阈值 1MB + 通用回收入口。

基于已打 v1 补丁的 repo-r5（FastllmCudaTrimIdleBigBuffers + qwen3_5 两处调用）：
  1) fastllm-cuda.cu：新增统一入口 FastllmCudaRequestEndPoolTrim()
     （env 门控；FT_QWEN35_REQUEST_POOL_TRIM 默认开；阈值默认 1MB）。
  2) fastllm-cuda.cuh：声明该入口。
  3) qwen3_5.cpp：删除两个静态助手，两处调用改走统一入口。
  4) basellm.cpp：basellm::RemoveResponseContext 末尾调用统一入口
     —— 覆盖所有请求完成路径（不限 MTP/多模态）。

幂等：检测到 FastllmCudaRequestEndPoolTrim 已存在则跳过。
"""
import sys
from pathlib import Path

R = Path("/home/ai-agent/builds/upgrade-test/repo-r5")
CU = R / "src/devices/cuda/fastllm-cuda.cu"
CUH = R / "include/devices/cuda/fastllm-cuda.cuh"
Q = R / "src/models/qwen3_5.cpp"
B = R / "src/models/basellm.cpp"

WRAPPER = r'''
// 请求结束统一回收入口（env 门控：FT_QWEN35_REQUEST_POOL_TRIM 默认开，=0 关闭；
// 阈值 FT_QWEN35_REQUEST_POOL_TRIM_MIN_MB 默认 1MB）。在请求结束/移除路径调用，
// 避免长会话下 big 池空闲块无上限累积（2026-09-16 OOM 取证）。
void FastllmCudaRequestEndPoolTrim() {
    static int enabled = -1;
    static size_t minBytes = 0;
    if (enabled < 0) {
        const char *e = getenv("FT_QWEN35_REQUEST_POOL_TRIM");
        enabled = (e == nullptr || atoi(e) != 0) ? 1 : 0;
        const char *m = getenv("FT_QWEN35_REQUEST_POOL_TRIM_MIN_MB");
        long long mb = (m != nullptr) ? atoll(m) : 1;
        if (mb <= 0) {
            mb = 1;
        }
        minBytes = (size_t)mb * 1024ULL * 1024ULL;
    }
    if (!enabled) {
        return;
    }
    FastllmCudaTrimIdleBigBuffers(minBytes);
}

'''

CU_ANCHOR = "void FastllmCudaClearBigBuffer() {"

CUH_OLD = "void FastllmCudaTrimIdleBigBuffers(size_t minBytes);\n"
CUH_NEW = ("void FastllmCudaTrimIdleBigBuffers(size_t minBytes);\n"
           "void FastllmCudaRequestEndPoolTrim();\n")

Q_HELPERS_OLD = """
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

Q_END_OLD = """                    eraseMtpCache(ctx);
                    if (Qwen35RequestPoolTrimEnabled()) {
                        FastllmCudaTrimIdleBigBuffers(
                            Qwen35RequestPoolTrimMinBytes());
                    }
                    continue;
"""
Q_END_NEW = """                    eraseMtpCache(ctx);
                    FastllmCudaRequestEndPoolTrim();
                    continue;
"""

Q_ABORT_OLD = """            if (!abortHandles.empty() && Qwen35RequestPoolTrimEnabled()) {
                FastllmCudaTrimIdleBigBuffers(Qwen35RequestPoolTrimMinBytes());
            }
"""
Q_ABORT_NEW = """            if (!abortHandles.empty()) {
                FastllmCudaRequestEndPoolTrim();
            }
"""

B_OLD = """        responseContextDict.RemoveHandle(handleId);
    }
"""
B_NEW = """        responseContextDict.RemoveHandle(handleId);
        FastllmCudaRequestEndPoolTrim();
    }
"""


def patch(path, old, new, label):
    text = path.read_text(encoding="utf-8")
    n = text.count(old)
    if n != 1:
        print(f"ASSERT_FAIL {label}: expected 1 occurrence, found {n}", flush=True)
        sys.exit(2)
    path.write_text(text.replace(old, new, 1), encoding="utf-8")
    print(f"OK {label}", flush=True)


def main():
    if "FastllmCudaRequestEndPoolTrim" in CU.read_text(encoding="utf-8"):
        print("ALREADY_PATCHED_V2", flush=True)
        sys.exit(0)
    if "FastllmCudaTrimIdleBigBuffers" not in CU.read_text(encoding="utf-8"):
        print("V1_PATCH_MISSING", flush=True)
        sys.exit(2)

    patch(CU, CU_ANCHOR, WRAPPER.lstrip("\n") + CU_ANCHOR, "cuda-wrapper")
    patch(CUH, CUH_OLD, CUH_NEW, "cuh-decl-v2")
    patch(Q, Q_HELPERS_OLD, "", "qwen-drop-helpers")
    patch(Q, Q_END_OLD, Q_END_NEW, "qwen-end-v2")
    patch(Q, Q_ABORT_OLD, Q_ABORT_NEW, "qwen-abort-v2")
    patch(B, B_OLD, B_NEW, "basellm-remove-hook")
    print("PATCH_V2_APPLIED", flush=True)


if __name__ == "__main__":
    main()
