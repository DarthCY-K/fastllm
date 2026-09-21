#!/usr/bin/env python3
"""SSD 前缀缓存 v2：launcher 补丁（迁 RAID0 / 配额 32GiB / 挂载守卫）。幂等，锚点不匹配则中止。"""
import shutil, sys, os

F = "/home/ai-agent/fastllm-video-repro/fastllm_prod_launch.py"
BAK = F + ".bak-pre-ssd-v2-20260921"

OLD = """os.environ['FASTLLM_PREFIX_CACHE'] = 'true'
os.environ['FASTLLM_MULTIMODAL_PREFIX_CACHE'] = '1'
os.environ['FASTLLM_PREFIX_CACHE_DIR'] = '/home/ai-agent/prefix_ssd_prod'
# 2026-09-21b: 64→16GiB——约束首请求全量读取校验成本（≈存储/295MB/s；16GiB≈55s上限）；配合 scripts/warmup_prod.sh 兜底
os.environ['FASTLLM_PREFIX_CACHE_DISK_BYTES'] = str(16 << 30)
os.environ['FASTLLM_PREFIX_CACHE_RESTORE_POLICY'] = 'always'"""

NEW = """# 2026-09-21夜 v2: 移驻 RAID0（/var/cache/lmcache）、配额 32GiB 起步、挂载守卫；
# 自动暖机由 systemd ExecStartPost（/home/ai-agent/ops/warmup_on_start.sh）承担。
# 撤销 = 恢复 .bak-pre-ssd-v2-20260921 + 重启。
_SSD_ROOT = '/var/cache/lmcache'
_SSD_DIR_V2 = _SSD_ROOT + '/prefix_ssd_prod'
if os.path.ismount(_SSD_ROOT) and os.path.isdir(_SSD_DIR_V2) and os.access(_SSD_DIR_V2, os.W_OK):
    os.environ['FASTLLM_PREFIX_CACHE'] = 'true'
    os.environ['FASTLLM_MULTIMODAL_PREFIX_CACHE'] = '1'
    os.environ['FASTLLM_PREFIX_CACHE_DIR'] = _SSD_DIR_V2
    os.environ['FASTLLM_PREFIX_CACHE_DISK_BYTES'] = str(32 << 30)
    os.environ['FASTLLM_PREFIX_CACHE_RESTORE_POLICY'] = 'always'
    print('[prod-launch] SSD prefix cache: %s (quota=32GiB restore=always)' % _SSD_DIR_V2, flush=True)
else:
    print('[prod-launch] WARNING: SSD prefix cache DISABLED: %s not mounted or %s missing' % (_SSD_ROOT, _SSD_DIR_V2), flush=True)"""

s = open(F, encoding="utf-8").read()
if "_SSD_DIR_V2" in s:
    print("already patched"); sys.exit(0)
if OLD not in s:
    sys.exit("OLD block not found — abort, no change made")
if os.path.exists(BAK):
    sys.exit("backup already exists: " + BAK)
shutil.copy2(F, BAK)
open(F + ".new", "w", encoding="utf-8").write(s.replace(OLD, NEW))
shutil.move(F + ".new", F)
print("patched OK; backup:", BAK)
