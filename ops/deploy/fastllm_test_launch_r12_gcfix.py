#!/usr/bin/env python
# r12 gcfix test launcher (8081). 与 fastllm_test_launch_r12_ssd.py 同一骨架，
# 差异仅在: PYTHONPATH / SSD 目录 / 配额 由环境变量参数化（供同窗口 A/B）。
#   GCFIX_PYTHONPATH  默认 overlay-r12-gcfix
#   GCFIX_SSD         默认 /home/ai-agent/prefix_ssd_gcfixtest
#   GCFIX_DISK_BYTES  默认 4GiB
# ARGV_FILE 选 argv；DFLASH_TB=force/off；TRITON_SM75=1 开 SM75 Triton GDN prefill。
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
triton_sm75 = os.environ.get('TRITON_SM75', '0')
ppath = os.environ.get('GCFIX_PYTHONPATH', str(W / 'overlay-r12-gcfix'))
ssd = os.environ.get('GCFIX_SSD', '/home/ai-agent/prefix_ssd_gcfixtest')
disk = os.environ.get('GCFIX_DISK_BYTES', str(4 << 30))
for k in list(os.environ):
    if k.startswith('FASTLLM_') or k in ['PYTHONPATH', 'LD_LIBRARY_PATH']:
        os.environ.pop(k, None)
os.environ.update(CUDA_VISIBLE_DEVICES='0,3,1,2', CUDA_DEVICE_ORDER='PCI_BUS_ID', PYTHONUNBUFFERED='1')
os.environ['PYTHONPATH'] = ppath
if dflash_tb != 'off':
    os.environ['FASTLLM_CUDA_DFLASH_TP_BACKBONE'] = dflash_tb
os.environ['FASTLLM_QWEN35_MTP_PROFILE'] = '64'
os.environ['FASTLLM_QWEN35_MTP_WORKER_PROFILE'] = '64'
os.environ['NCCL_PROTO'] = 'LL128'
os.environ['FASTLLM_ALLOW_YARN_WITH_DFLASH'] = '1'
os.environ['FT_TOOLCALL_DEBUG_OUTPUT'] = '1'
if triton_sm75 == '1':
    os.environ['FASTLLM_CUDA_TRITON'] = '1'
    os.environ['FASTLLM_CUDA_TRITON_PYTHON'] = str(Path.home() / '.venvs' / 'fastllm-triton-sm75' / 'bin' / 'python')
# --- persistent prefix cache (test dir, parametrized) ---
os.environ['FASTLLM_PREFIX_CACHE'] = 'true'
os.environ['FASTLLM_MULTIMODAL_PREFIX_CACHE'] = '1'
os.environ['FASTLLM_PREFIX_CACHE_DIR'] = ssd
os.environ['FASTLLM_PREFIX_CACHE_DISK_BYTES'] = disk
os.environ['FASTLLM_PREFIX_CACHE_RESTORE_POLICY'] = 'always'
print(f"[gcfix-launch] pythonpath={ppath} ssd={ssd} disk={disk} argv_file={argv_file}", flush=True)
os.execv(argv[0], argv)
