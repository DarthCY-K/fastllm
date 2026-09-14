#pragma once
// Lossless W8A16 storage: group [q+128 x128][raw LE BF16 scale x2].
// No activation quantization, FP16 scale conversion, or dequantized weight cache.
#include <cuda_runtime.h>
#include <cuda_fp16.h>
#include <cuda_bf16.h>
#include <cstdint>

namespace fastllm_packed_int8_cuda {
template<int Type> __device__ inline float Load(const void *p, size_t i) {
    if constexpr(Type == 0) return ((const float*)p)[i];
    if constexpr(Type == 1) return __half2float(((const __half*)p)[i]);
    if constexpr(Type == 2) return __uint_as_float(unsigned(((const uint16_t*)p)[i]) << 16);
}
template<int Type> __device__ inline void Store(void *p, size_t i, float v) {
    if constexpr(Type == 0) ((float*)p)[i] = v;
    if constexpr(Type == 1) ((__half*)p)[i] = __float2half_rn(v);
    if constexpr(Type == 2) ((__nv_bfloat16*)p)[i] = __float2bfloat16_rn(v);
}
template<int Type> __global__ void Linear(const void *x, const uint8_t *w,
        const float *bias, void *y, int K, int N, size_t outputs, bool add) {
    // One CTA per dot product; grid-stride supports arbitrary batch/MTP length.
    for(size_t out=blockIdx.x; out<outputs; out+=gridDim.x) {
        size_t row=out % N, batch=out / N;
        const uint8_t *base=w + row * (size_t(K)/128)*130;
        float sum=0;
        for(int g=0;g<K/128;g++) {
            const uint8_t *p=base + size_t(g)*130;
            float scale=__uint_as_float(unsigned(p[128] | (unsigned(p[129])<<8))<<16);
            float weight=float(int(p[threadIdx.x])-128)*scale;
            sum=fmaf(Load<Type>(x,batch*K+g*128+threadIdx.x),weight,sum);
        }
        for(int d=16;d>0;d>>=1) sum+=__shfl_down_sync(0xffffffff,sum,d);
        __shared__ float warps[4];
        if((threadIdx.x&31)==0) warps[threadIdx.x/32]=sum;
        __syncthreads();
        if(threadIdx.x==0) {
            float v=((warps[0]+warps[1])+warps[2])+warps[3];
            if(bias) v+=bias[row];
            if(add) v+=Load<Type>(y,out);
            Store<Type>(y,out,v);
        }
        __syncthreads();
    }
}
inline cudaError_t Launch(const void *x, const uint8_t *w, const float *bias,
        void *y, int B, int K, int N, int type, bool add,
        cudaStream_t stream=cudaStreamPerThread) {
    if(B<0 || N<0 || K<=0 || K%128 || type<0 || type>2) return cudaErrorInvalidValue;
    if(B==0 || N==0) return cudaSuccess;
    if(!x || !w || !y) return cudaErrorInvalidValue;
    size_t outputs=size_t(B)*N;
    unsigned blocks=unsigned(outputs<65535?outputs:65535);
    if(type==0) Linear<0><<<blocks,128,0,stream>>>(x,w,bias,y,K,N,outputs,add);
    if(type==1) Linear<1><<<blocks,128,0,stream>>>(x,w,bias,y,K,N,outputs,add);
    if(type==2) Linear<2><<<blocks,128,0,stream>>>(x,w,bias,y,K,N,outputs,add);
    return cudaGetLastError();
}
}
