#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""apply_mm_restore_guard.py — 视觉前缀复原保护补丁（2026-09-17）。

背景（2026-09-17 复现+定位）：请求前缀被复原（prefix cache restored: tokens=N>0）时，
增量区里的新图片完全不经视觉通路 —— Qwen35ForwardMultimodalInternal 的复原分支
（qwen3_5.cpp，pastKeyValues 非空）直接走普通 Forward/Qwen35MTPForward，绕过
EncodeVisualItems/BuildMultimodalPositionData，模型对着空占位符编造内容。

补丁内容（qwen3_5.cpp 单文件）：
  1) 匿名命名空间新增两个静态助手：
     - Qwen35MmRestoreGuardEnabled()（默认开，FT_QWEN35_MM_RESTORE_GUARD=0 关闭）
     - Qwen35RangeContainsMediaTokens()（扫描 token 序列 [start,end) 是否含图像/视频占位 token）
  2) tryRestorePrefixCache（Qwen35MTPLoop 内）在 cachedLen 最终确定后、执行破坏性复原前，
     检查增量区（[cachedLen, size)）是否含媒体占位 token：命中则打印一行并放弃复原
     （return 0 → 走全量冷预填，正确优先）。仅破坏性复原前拦截，文本增量复原不受影响。

用法：python3 apply_mm_restore_guard.py [目标树根目录，默认 repo-r5]
幂等：检测到 Qwen35MmRestoreGuardEnabled 已存在则跳过。
备份：目标树内 qwen3_5.cpp.bak-pre-mmguard（首次生成）。
"""
import sys
from pathlib import Path

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else
            "/home/ai-agent/builds/upgrade-test/repo-r5")
Q = ROOT / "src/models/qwen3_5.cpp"
MARKER = "Qwen35MmRestoreGuardEnabled"

HELPERS_OLD = """        static bool Qwen35MmcacheSeedEnabled() {
            static int v = -1;
            if (v < 0) {
                const char *e = getenv("FT_QWEN35_MM_CACHE_SEED");
                v = (e == nullptr || atoi(e) != 0) ? 1 : 0;
            }
            return v != 0;
        }
    }
"""

HELPERS_NEW = """        static bool Qwen35MmcacheSeedEnabled() {
            static int v = -1;
            if (v < 0) {
                const char *e = getenv("FT_QWEN35_MM_CACHE_SEED");
                v = (e == nullptr || atoi(e) != 0) ? 1 : 0;
            }
            return v != 0;
        }

        // 视觉复原保护（默认开，FT_QWEN35_MM_RESTORE_GUARD=0 关闭）：复原分支的
        // 增量前向不经过视觉编码（EncodeVisualItems/BuildMultimodalPositionData
        // 只在冷算路径），增量区含图像/视频占位 token 时继续复原会让模型对着空
        // 占位符编造内容（2026-09-17 复现）→ 此时放弃复原，走全量冷预填。
        static bool Qwen35MmRestoreGuardEnabled() {
            static int v = -1;
            if (v < 0) {
                const char *e = getenv("FT_QWEN35_MM_RESTORE_GUARD");
                v = (e == nullptr || atoi(e) != 0) ? 1 : 0;
            }
            return v != 0;
        }

        static bool Qwen35RangeContainsMediaTokens(const std::vector <int> &tokens,
                                                   int start, int imageTok,
                                                   int videoTok) {
            if (imageTok < 0 && videoTok < 0) {
                return false;
            }
            if (start < 0) {
                start = 0;
            }
            for (int i = start; i < (int)tokens.size(); i++) {
                if ((imageTok >= 0 && tokens[i] == imageTok) ||
                    (videoTok >= 0 && tokens[i] == videoTok)) {
                    return true;
                }
            }
            return false;
        }
    }
"""

GUARD_OLD = """            cachedLen = minCachedPages * probeManager->pageLen;
            if (!model->RestorePagedPrefixCacheExtra(ctx, cachedLen)) {
                return -1;
            }
"""

GUARD_NEW = r"""            cachedLen = minCachedPages * probeManager->pageLen;
            if (Qwen35MmRestoreGuardEnabled() &&
                Qwen35RangeContainsMediaTokens(ctx->currentTokens, cachedLen,
                                               model->image_token_id,
                                               model->video_token_id)) {
                // 增量区含图像/视频占位 token：复原路径（Qwen35ForwardMultimodalInternal
                // 的 pastKeyValues 分支）不会为新图做视觉编码，继续复原会让模型对着
                // 空占位符编造描述 → 放弃复原，走全量冷预填（正确优先）。
                // 关闭保护：FT_QWEN35_MM_RESTORE_GUARD=0。
                printf("[Qwen3.5 MM] prefix restore skipped: media tokens in "
                       "delta (restore_len=%d, total=%d).\n",
                       cachedLen, (int)ctx->currentTokens.size());
                fflush(stdout);
                return 0;
            }
            if (!model->RestorePagedPrefixCacheExtra(ctx, cachedLen)) {
                return -1;
            }
"""


def patch(path, old, new, label):
    text = path.read_text(encoding="utf-8")
    n = text.count(old)
    if n != 1:
        print("ASSERT_FAIL %s: expected 1 occurrence, found %d" % (label, n),
              flush=True)
        sys.exit(2)
    path.write_text(text.replace(old, new, 1), encoding="utf-8")
    print("OK %s" % label, flush=True)


def main():
    if not Q.exists():
        print("SRC_MISSING %s" % Q, flush=True)
        sys.exit(2)
    text = Q.read_text(encoding="utf-8")
    if MARKER in text:
        print("ALREADY_PATCHED", flush=True)
        sys.exit(0)
    bak = Q.with_name(Q.name + ".bak-pre-mmguard")
    if not bak.exists():
        bak.write_text(text, encoding="utf-8")
        print("BACKUP %s" % bak, flush=True)
    patch(Q, HELPERS_OLD, HELPERS_NEW, "qwen-guard-helpers")
    patch(Q, GUARD_OLD, GUARD_NEW, "qwen-restore-guard")
    print("PATCH_APPLIED", flush=True)


if __name__ == "__main__":
    main()
