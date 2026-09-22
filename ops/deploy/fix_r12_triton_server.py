#!/usr/bin/env python3
# fix_r12_triton_server.py — 修复 SM75 Triton GDN 预填充的部署缺口（幂等；默认只检查，加 --apply 才动文件）
#
# 背景（2026-09-22 诊断）：
#   引擎会用它加载的 .so 同目录下的 fastllm_triton_server.py 作为编译服务脚本。
#   生产那份（site-packages/ftllm/，与 overlay-r12/ftllm/ 同版）= 2026-09-22 00:05 旧版（md5 8a77e4cf…），
#   在 triton 3.2.0 下 ASTSource 用旧关键字 constexprs= 直接 TypeError
#   → "chunk GDN prefill compile failed; falling back to built-in CUDA"（引擎静默回退，且本进程内不再重试）。
#   修好的版本（md5 3fe7b8ef…，含 constants= 兼容分支 + v9 内核）在 build-r12/tools/ftllm/ 与 wt-r12/tools/，
#   但从未同步进任何生产位置。
import hashlib, shutil, sys, time
from pathlib import Path

FIXED_MD5 = "3fe7b8efd65928877a05516a6169f659"
SRC = Path("/home/ai-agent/builds/upgrade-test/build-r12/tools/ftllm/fastllm_triton_server.py")
TARGETS = [
    Path("/home/ai-agent/builds/fastllm-video-venv/lib/python3.13/site-packages/ftllm/fastllm_triton_server.py"),
    Path("/home/ai-agent/builds/upgrade-test/overlay-r12/ftllm/fastllm_triton_server.py"),
]
APPLY = "--apply" in sys.argv

def md5(p): return hashlib.md5(p.read_bytes()).hexdigest()

def main():
    if not SRC.exists():
        print("SRC_MISSING:", SRC); return 2
    if md5(SRC) != FIXED_MD5:
        print("SRC_MD5_MISMATCH:", md5(SRC)); return 2
    print("SRC ok (fixed rev):", SRC, md5(SRC))
    stamp = time.strftime("%Y%m%d-%H%M%S")
    todo, done = [], []
    for t in TARGETS:
        if not t.exists():
            print("SKIP (missing):", t); continue
        cur = md5(t)
        if cur == FIXED_MD5:
            print("ALREADY_FIXED:", t); done.append(t); continue
        todo.append((t, cur))
    if not todo:
        print("NOTHING_TO_DO"); return 0
    for t, cur in todo:
        print("NEEDS_PATCH:", t, "(current", cur[:12] + ")")
        if APPLY:
            bak = t.with_name(t.name + ".bak-pre-triton-fix-" + stamp)
            shutil.copy2(t, bak)
            shutil.copy2(SRC, t)
            if md5(t) != FIXED_MD5:
                print("VERIFY_FAILED:", t); return 3
            print("PATCHED:", t, "backup:", bak.name)
    print()
    print("生效步骤（三项缺一不可）:")
    print("  1) pkill -f fastllm_triton_server   # 现在挂着的服务内存里是旧代码；引擎会按 .so 同目录的新文件自动重拉")
    print("  2) 重启生产（引擎内 failedSm75Meta 是进程级缓存，不重启不会重试）")
    print("  3) 重启后第一发 chunked prefill 起：")
    print("     引擎日志中不再出现 'chunk GDN prefill compile failed'；")
    print("     ls -l ~/.cache/fastllm/triton/ 出现新的 chunk_gdn_prefill_v9_* 文件（mtime=刚才）")
    print("回滚：把同目录 *.bak-pre-triton-fix-*  拷回原名即可。")
    return 0

if __name__ == "__main__":
    sys.exit(main())
