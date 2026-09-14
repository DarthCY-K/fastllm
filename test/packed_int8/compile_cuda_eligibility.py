from pathlib import Path
import subprocess,shlex,sys
root=Path('/home/ai-agent/builds/packed-int8-cuda-agent')
source=Path('/home/ai-agent/builds/fastllm-b9399ac3b7ed3beebb8b1af035fa519118852280')
stage=root/'stage'
flags=Path('/home/ai-agent/builds/fastllm-build-parent/CMakeFiles/fastllm.dir/flags.make').read_text()
incs=shlex.split(next(s.split(' = ',1)[1] for s in flags.splitlines() if s.startswith('CXX_INCLUDES =')))
args=[s.replace(str(source),str(stage)) for s in incs]+incs+['-DUSE_CUDA','-DUSE_NUMAS']
for label,src in [('baseline',source),('current',stage)]:
    obj=root/(label+'-eligibility.o')
    subprocess.run(['g++-13','-O0','-std=c++17','-ffunction-sections','-fdata-sections']+args+['-c',str(src/'src/devices/cuda/cudadevice.cpp'),'-o',str(obj)],check=True)
    exe=root/(label+'-eligibility')
    subprocess.run(['g++-13','-std=c++17']+args+[str(root/'test_cuda_eligibility.cpp'),str(obj),'-Wl,--gc-sections','-pthread','-o',str(exe)],check=True)
    r=subprocess.run([str(exe)])
    print(label,'exit',r.returncode,flush=True)
    if (label=='baseline' and r.returncode!=1) or (label=='current' and r.returncode!=0): sys.exit(1)
