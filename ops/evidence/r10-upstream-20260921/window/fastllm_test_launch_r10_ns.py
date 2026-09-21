#!/usr/bin/env python
# Swift trial launcher NO-SPEC (8081). Target = staging/swift-qwen38-nvfp4.
# Env contract mirrors fastllm_prod_launch.py; PYTHONPATH -> overlay-r10.
import os, sys, json
from pathlib import Path

W = Path('/home/ai-agent/builds/upgrade-test')
argv = json.loads((W / 'argv-swift-trial-ns.json').read_text())['argv'].copy()

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

for k in list(os.environ):
    if k.startswith('FASTLLM_') or k in ['PYTHONPATH', 'LD_LIBRARY_PATH']:
        os.environ.pop(k, None)
os.environ.update(CUDA_VISIBLE_DEVICES='0,3,1,2', CUDA_DEVICE_ORDER='PCI_BUS_ID', PYTHONUNBUFFERED='1')
os.environ['PYTHONPATH'] = str(W / 'overlay-r10')
os.environ['FASTLLM_CUDA_DFLASH_TP_BACKBONE'] = 'force'
os.environ['FASTLLM_QWEN35_MTP_PROFILE'] = '64'
os.environ['FASTLLM_QWEN35_MTP_WORKER_PROFILE'] = '64'
os.environ['NCCL_PROTO'] = 'LL128'
os.environ['FASTLLM_ALLOW_YARN_WITH_DFLASH'] = '1'
os.environ['FT_TOOLCALL_DEBUG_OUTPUT'] = '1'
os.execv(argv[0], argv)
