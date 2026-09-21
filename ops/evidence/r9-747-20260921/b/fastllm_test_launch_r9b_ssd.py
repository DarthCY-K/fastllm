#!/usr/bin/env python
# r8 test launcher (8081) for the Swift trial. PYTHONPATH -> overlay-r9b.
# ARGV_FILE env selects the argv: argv-swift-trial-ns.json (default, no spec) or argv-swift-trial.json (dflash).
import os, sys, json
from pathlib import Path

W = Path('/home/ai-agent/builds/upgrade-test')
argv_file = os.environ.get('ARGV_FILE', 'argv-swift-trial-ns.json')
argv = json.loads((W / argv_file).read_text())['argv'].copy()

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

dflash_tb = os.environ.get('DFLASH_TB', 'force')
for k in list(os.environ):
    if k.startswith('FASTLLM_') or k in ['PYTHONPATH', 'LD_LIBRARY_PATH']:
        os.environ.pop(k, None)
os.environ.update(CUDA_VISIBLE_DEVICES='0,3,1,2', CUDA_DEVICE_ORDER='PCI_BUS_ID', PYTHONUNBUFFERED='1')
os.environ['PYTHONPATH'] = str(W / 'overlay-r9b')
if dflash_tb != 'off':
    os.environ['FASTLLM_CUDA_DFLASH_TP_BACKBONE'] = dflash_tb
os.environ['FASTLLM_QWEN35_MTP_PROFILE'] = '64'
os.environ['FASTLLM_QWEN35_MTP_WORKER_PROFILE'] = '64'
os.environ['NCCL_PROTO'] = 'LL128'
os.environ['FASTLLM_ALLOW_YARN_WITH_DFLASH'] = '1'
os.environ['FT_TOOLCALL_DEBUG_OUTPUT'] = '1'
# --- persistent prefix cache (PR#747, test dir) ---
SSD = '/home/ai-agent/prefix_ssd_r9b'
os.environ['FASTLLM_PREFIX_CACHE'] = 'true'
os.environ['FASTLLM_MULTIMODAL_PREFIX_CACHE'] = '1'
os.environ['FASTLLM_PREFIX_CACHE_DIR'] = SSD
os.environ['FASTLLM_PREFIX_CACHE_DISK_BYTES'] = str(64 << 30)
os.environ['FASTLLM_PREFIX_CACHE_RESTORE_POLICY'] = 'always'

os.execv(argv[0], argv)
