// Host-only eligibility test: link cudadevice.cpp with -ffunction-sections -Wl,--gc-sections.
#include "fastllm.h"
#include "devices/cpu/cpudevice.h"
#include "devices/cuda/cudadevice.h"
#include <cstdio>
int main() {
    using namespace fastllm;
    for(auto type: {FLOAT32,FLOAT16,BFLOAT16}) {
        if(!IsCudaLinearDataTypeSupported(type,PACKED_INT8_GROUP128_BF16,FLOAT32)) {
            std::fprintf(stderr,"FAIL: packed INT8 CUDA activation type %d rejected\n",int(type)); return 1;
        }
        if(IsCudaLinearDataTypeSupported(type,PACKED_INT8_GROUP128_BF16,FLOAT16)) return 2;
    }
    if(IsCudaLinearDataTypeSupported(INT8,PACKED_INT8_GROUP128_BF16,FLOAT32)) return 3;
    std::puts("PASS: actual CUDA dispatch eligibility supports FP32/FP16/BF16 and rejects unsupported combinations; no GPU calls");
}
