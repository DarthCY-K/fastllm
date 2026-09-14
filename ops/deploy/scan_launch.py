#!/usr/bin/env python
# SCAN launcher: 生产 argv（overlay-fix 代码）+ 端口改 8081 + SCAN_ENV / SCAN_ARGV 覆盖。
# SCAN_ENV:  分号分隔的 KEY=VALUE（如 "A=0;B=force"），空 = 基线。
# SCAN_ARGV: 分号分隔的 FLAG=VALUE（如 "--chunked_prefill_size=1024"），替换 argv 中该 flag 的
#            当前值；flag 不存在则追加；"--flag="（空值）删除该 flag 及其值。
# 2026-09-14 夜窗口: 默认 backbone 改为 force（对齐生产 launcher）。
import os, sys, json
from pathlib import Path

W = Path('/home/ai-agent/builds/upgrade-test')
R = Path('/home/ai-agent/fastllm-video-repro')
argv = json.loads((R / 'results/argv-prod-tp4.json').read_text())['argv'].copy()

scan_env = os.environ.get('SCAN_ENV') or ''
scan_argv = os.environ.get('SCAN_ARGV') or ''

key = ''
for line in Path('/home/ai-agent/qwen38-0.2x.env').read_text().splitlines():
    line = line.strip()
    if line.startswith('VLLM_API_KEY='):
        key = line.split('=', 1)[1].strip().strip('"').strip("'")
        break
if not key:
    sys.exit('FATAL: VLLM_API_KEY not found')
if '--api_key' in argv:
    argv[argv.index('--api_key') + 1] = key
if '--port' in argv:
    argv[argv.index('--port') + 1] = '8081'

for pair in scan_argv.split(';'):
    pair = pair.strip()
    if not pair:
        continue
    flag, sep, val = pair.partition('=')
    flag = flag.strip()
    if not flag:
        continue
    if flag in argv:
        i = argv.index(flag)
        if sep and val.strip() == '':
            # remove flag and its value (if the value slot holds a literal)
            del argv[i]
            if i < len(argv) and not argv[i].startswith('--'):
                del argv[i]
        elif i + 1 < len(argv) and not argv[i + 1].startswith('--'):
            argv[i + 1] = val.strip()
        elif sep:
            argv.insert(i + 1, val.strip())
    elif sep and val.strip() != '':
        argv += [flag, val.strip()]

for k in list(os.environ):
    if k.startswith('FASTLLM_') or k in ['PYTHONPATH', 'LD_LIBRARY_PATH']:
        os.environ.pop(k, None)
os.environ.update(CUDA_VISIBLE_DEVICES='0,3,1,2', CUDA_DEVICE_ORDER='PCI_BUS_ID', PYTHONUNBUFFERED='1')
os.environ['PYTHONPATH'] = str(W / 'overlay-fix')
os.environ['FASTLLM_CUDA_DFLASH_TP_BACKBONE'] = 'force'
os.environ['FASTLLM_QWEN35_MTP_PROFILE'] = '64'
os.environ['FASTLLM_QWEN35_MTP_WORKER_PROFILE'] = '64'
os.environ['FASTLLM_ALLOW_YARN_WITH_DFLASH'] = '1'
os.environ['FT_TOOLCALL_DEBUG_OUTPUT'] = '1'
for pair in scan_env.split(';'):
    pair = pair.strip()
    if pair and '=' in pair:
        k, v = pair.split('=', 1)
        os.environ[k.strip()] = v.strip()


def argval(flag, default='-'):
    if flag in argv:
        i = argv.index(flag)
        if i + 1 < len(argv):
            return argv[i + 1]
    return default


print('[scan_launch] SCAN_ENV=%s | SCAN_ARGV=%s' % (scan_env, scan_argv), flush=True)
print('[scan_launch] effective chunk=%s interval_pages=%s backbone=%s' % (
    argval('--chunked_prefill_size'), argval('--prefix_cache_snapshot_interval_pages'),
    os.environ.get('FASTLLM_CUDA_DFLASH_TP_BACKBONE')), flush=True)
os.execv(argv[0], argv)
