"""CPU-only acceptance using real-row fixtures supplied by the model audit."""
import ctypes, json, pathlib, subprocess, sys
import numpy as np
root, fixtures = map(pathlib.Path,sys.argv[1:3])
work=pathlib.Path(__file__).resolve().parent
wrapper=work/'native_wrapper.cpp'
wrapper.write_text('#include "packedint8.h"\nextern "C" void linear(const uint16_t*x,const uint8_t*w,const uint16_t*s,float*y,size_t n,size_t b){fastllm::PackedInt8Group128LinearF16(x,w,s,nullptr,y,b,1,n);}\nextern "C" int exact(uint16_t s){try{return fastllm::PackedInt8ExactHalfScale(s);}catch(...){return -1;}}\n')
subprocess.run(['g++','-std=c++17','-O2','-shared','-fPIC','-Wall','-Wextra','-Werror','-I'+str(root/'include'),str(wrapper),'-o',str(work/'native.so')],check=True)
lib=ctypes.CDLL(str(work/'native.so'))
lib.linear.argtypes=[ctypes.c_void_p]*4+[ctypes.c_size_t]*2
lib.exact.argtypes=[ctypes.c_uint16]; lib.exact.restype=ctypes.c_int
# Exhaust every nonnegative BF16 code against independent NumPy IEEE conversion.
with np.errstate(over='ignore',invalid='ignore'):
 for bits in range(32768):
  f=np.array([bits<<16],dtype=np.uint32).view(np.float32)[0]
  h=np.float16(f)
  expected=np.isfinite(f) and np.float32(h)==f
  result=lib.exact(bits)
  assert (result>=0)==expected,(bits,float(f),result)
  if expected: assert result==int(np.array([h],dtype=np.float16).view(np.uint16)[0])
records=[]
for case in json.loads((fixtures/'manifest.json').read_text()):
 z=np.load(case['file']); w=np.ascontiguousarray(z['packed']).view(np.uint8).ravel()
 scale=np.ascontiguousarray(z['scale'],dtype=np.float32).ravel()
 s=(scale.view(np.uint32)>>16).astype(np.uint16)
 assert np.array_equal((s.astype(np.uint32)<<16).view(np.float32),scale)
 # Half activations required by W8A16; expected recomputed after this conversion.
 x=np.ascontiguousarray(z['input'],dtype=np.float16).ravel(); y=np.zeros(x.size//w.size,dtype=np.float32)
 expected=np.dot(x.astype(np.float64).reshape(-1,w.size),z['weight'].ravel().astype(np.float64))
 lib.linear(x.ctypes.data,w.ctypes.data,s.ctypes.data,y.ctypes.data,w.size,y.size)
 error=float(np.max(np.abs(y-expected)))
 bound=2e-5*float(np.abs(x.astype(np.float64).reshape(-1,w.size)*z['weight'].ravel()).sum())+1e-7
 assert error<=bound,(case,error,bound)
 records.append({'name':case['name'],'non_fp16_scale':case['non_fp16_scale'],'output':y.tolist(),'reference':expected.tolist(),'abs_error':error,'bound':bound})
assert len(records)==8
(work/'real-results.json').write_text(json.dumps(records,indent=2))
print('PASS: 32768 nonnegative BF16 encodings checked; 8 real model rows incl all 7 tensors with non-FP16 scales; native W8A16 CPU outputs meet FP32 accumulation bound')
print(json.dumps(records,indent=2))
