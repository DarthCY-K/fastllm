#!/usr/bin/env python
# Test stack launcher, r2 build with snapshot interval forced back to 16 pages
# (r1-default regime: effective prefill chunk 512 instead of 256). NOT production.
import os, sys, json
from pathlib import Path

W = Path('/home/ai-agent/builds/upgrade-test')
argv = json.loads((W / 'argv-test-r2.json').read_text())['argv'].copy()

key = ''
env_path = Path('/home/ai-agent/qwen38-0.2x.env')
for line in env_path.read_text().splitlines():
    line = line.strip()
    if line.startswith('VLLM_API_KEY='):
        key = line.split('=', 1)[1].strip().strip('"').strip("'")
        break
if not key:
    sys.exit('FATAL: VLLM_API_KEY not found')
if '--api_key' in argv:
    argv[argv.index('--api_key') + 1] = key

for k in list(os.environ):
    if k.startswith('FASTLLM_') or k in ['PYTHONPATH', 'LD_LIBRARY_PATH']:
        os.environ.pop(k, None)
os.environ.update(CUDA_VISIBLE_DEVICES='0,3,1,2', CUDA_DEVICE_ORDER='PCI_BUS_ID', PYTHONUNBUFFERED='1')
os.environ['PYTHONPATH'] = str(W / 'overlay-r2')
os.environ['FASTLLM_CUDA_DFLASH_TP_BACKBONE'] = 'auto'
os.environ['FASTLLM_QWEN35_MTP_PROFILE'] = '64'
os.environ['FASTLLM_QWEN35_MTP_WORKER_PROFILE'] = '64'
os.environ['FASTLLM_ALLOW_YARN_WITH_DFLASH'] = '1'
os.environ['FT_TOOLCALL_DEBUG_OUTPUT'] = '1'
os.environ['FASTLLM_PREFIX_CACHE_SNAPSHOT_INTERVAL_PAGES'] = '16'
os.execv(argv[0], argv)
