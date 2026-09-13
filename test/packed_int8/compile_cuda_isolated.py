from pathlib import Path
import subprocess, shlex, sys, tarfile
root=Path('/home/ai-agent/builds/packed-int8-cuda-agent')
source=Path('/home/ai-agent/builds/fastllm-b9399ac3b7ed3beebb8b1af035fa519118852280')
with tarfile.open(root/'packed-int8-cuda-stage.tar.gz') as t: t.extractall(root/'stage',filter='data')
stage=root/'stage'
flags=(Path('/home/ai-agent/builds/fastllm-build-parent')/'CMakeFiles/fastllm.dir/flags.make').read_text()
incs=shlex.split(next(s.split(' = ',1)[1] for s in flags.splitlines() if s.startswith('CXX_INCLUDES =')))
overlay=[s.replace(str(source),str(stage)) for s in incs]
args=overlay+incs+['-I'+str(source/'src/devices/cuda'),'-I'+str(source/'src/devices/multicuda'),'-I/usr/local/cuda-12.8/include','-I/home/ai-agent/builds/fastllm-test-venv/lib/python3.13/site-packages/nvidia/nccl/include','-DUSE_CUDA','-DUSE_NUMAS','-DFASTLLM_SOURCE_DIR="'+str(stage)+'"']
for rel in ['src/devices/cuda/cudadevice.cpp','src/devices/multicuda/multicudadevice.cpp','src/devices/multicuda/fastllm-multicuda.cu','src/devices/cuda/fastllm-cuda.cu']:
    cmd=(['/usr/local/cuda-12.8/bin/nvcc','-ccbin','/usr/bin/g++-13','-std=c++20','-arch=sm_75','--default-stream=per-thread','--expt-relaxed-constexpr','--expt-extended-lambda'] if rel.endswith('.cu') else ['g++-13','-std=c++17','-pthread'])
    cmd+=['-O0']+args+['-c',str(stage/rel),'-o',str(root/(Path(rel).name+'.o'))]
    print('COMPILE',rel,flush=True)
    r=subprocess.run(cmd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
    (root/(Path(rel).name+'.compile.log')).write_text(r.stdout)
    print(r.stdout[-14000:] if r.returncode else 'warnings='+str(r.stdout.count('warning #'))+' (full log saved)',flush=True)
    print('EXIT',r.returncode,flush=True)
    if r.returncode: sys.exit(r.returncode)
print('PASS: four changed CUDA/multicuda translation units compiled; no GPU calls',flush=True)
