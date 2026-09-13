// nvcc -std=c++17 -arch=sm_75 -Iinclude/devices/cuda test/packed_int8/test_cuda_packed_int8.cu -o test_cuda_packed_int8
// Default is compile/host-only: NEVER touches CUDA. --run explicitly launches tiny fixtures.
#include "fastllm-cuda-packed-int8.cuh"
#include <cassert>
#include <cmath>
#include <cstring>
#include <iostream>
#include <vector>

static void check(cudaError_t e) { if(e != cudaSuccess) { std::cerr << cudaGetErrorString(e) << '\n'; std::exit(1); } }
int main(int argc, char **argv) {
    if(argc != 2 || std::strcmp(argv[1], "--run") != 0) {
        std::cout << "host-only: CUDA fixture compiled; no GPU calls\n";
        return 0;
    }
    // Includes BF16 scales not representable in FP16, signed extrema and multiple groups.
    const int K=256, N=3, B=9;
    std::vector<unsigned char> w(N*2*130);
    const unsigned short scales[] = {0x3b81, 0x3301, 0x3f81, 0x3801, 0x3a01, 0x3c80};
    for(int r=0;r<N;r++) for(int g=0;g<2;g++) {
        auto p=&w[(r*2+g)*130];
        for(int i=0;i<128;i++) p[i]=(i*13+r*31+g*7)%256;
        p[128]=scales[r*2+g]&255; p[129]=scales[r*2+g]>>8;
    }
    unsigned char *dw; check(cudaMalloc(&dw,w.size())); check(cudaMemcpy(dw,w.data(),w.size(),cudaMemcpyHostToDevice));
    float bias[N]={0.25f,-0.5f,1.0f}, *db; check(cudaMalloc(&db,sizeof(bias))); check(cudaMemcpy(db,bias,sizeof(bias),cudaMemcpyHostToDevice));
    for(int type=0;type<3;type++) for(int batch: {1,4,B}) for(bool add: {false,true}) {
        std::vector<float> x(batch*K), ref(batch*N), y(batch*N);
        std::vector<unsigned short> x16(batch*K), y16(batch*N);
        for(int i=0;i<batch*K;i++) {
            x[i]=float((i*7)%19-9)/8;
            if(type==1) { __half h=__float2half_rn(x[i]); std::memcpy(&x16[i],&h,2); }
            if(type==2) { unsigned bits; std::memcpy(&bits,&x[i],4); x16[i]=bits>>16; }
        }
        for(int b=0;b<batch;b++) for(int r=0;r<N;r++) {
            double sum=0;
            for(int c=0;c<K;c++) {
                auto p=&w[(r*2+c/128)*130]; unsigned bits=unsigned(p[128] | (p[129]<<8))<<16; float s; std::memcpy(&s,&bits,4);
                sum+=double(x[b*K+c])*float(int(p[c%128])-128)*s;
            }
            ref[b*N+r]=float(sum)+bias[r]+(add ? 1.0f : 0.0f);
        }
        void *dx,*dy; size_t element=type==0?4:2;
        check(cudaMalloc(&dx,x.size()*element)); check(cudaMalloc(&dy,y.size()*element));
        check(cudaMemcpy(dx,type==0?(void*)x.data():(void*)x16.data(),x.size()*element,cudaMemcpyHostToDevice));
        std::fill(y.begin(),y.end(),1.0f); std::fill(y16.begin(),y16.end(),type==1?0x3c00:0x3f80);
        check(cudaMemcpy(dy,type==0?(void*)y.data():(void*)y16.data(),y.size()*element,cudaMemcpyHostToDevice));
        check(fastllm_packed_int8_cuda::Launch(dx,dw,db,dy,batch,K,N,type,add,cudaStreamPerThread));
        check(cudaStreamSynchronize(cudaStreamPerThread));
        check(cudaMemcpy(type==0?(void*)y.data():(void*)y16.data(),dy,y.size()*element,cudaMemcpyDeviceToHost));
        for(size_t i=0;i<y.size();i++) {
            if(type==1) { __half h; std::memcpy(&h,&y16[i],2); y[i]=__half2float(h); }
            if(type==2) { unsigned bits=unsigned(y16[i])<<16; std::memcpy(&y[i],&bits,4); }
            float tol=(type==0?0.0002f:type==1?0.001f:0.008f)*std::max(1.0f,std::abs(ref[i]));
            if(std::abs(y[i]-ref[i])>tol) { std::cerr<<"mismatch type="<<type<<" batch="<<batch<<" i="<<i<<" actual="<<y[i]<<" ref="<<ref[i]<<'\n'; return 1; }
        }
        check(cudaFree(dx)); check(cudaFree(dy));
    }
    // Precision-sensitive probe: BF16 0x3301 rounds to a different FP16 value.
    // Multiply by an exactly representable activation, without larger terms/bias
    // that could hide scale rounding under a relative-error tolerance.
    std::vector<unsigned char> probe(130,128); probe[0]=129; probe[128]=1; probe[129]=0x33;
    check(cudaMemcpy(dw,probe.data(),probe.size(),cudaMemcpyHostToDevice));
    for(int type=0;type<3;type++) {
        std::vector<float> x(128,0.0f); x[0]=32768.0f;
        std::vector<unsigned short> x16(128,0); x16[0]=type==1?0x7800:0x4700;
        void *dx,*dy; size_t element=type==0?4:2;
        check(cudaMalloc(&dx,128*element)); check(cudaMalloc(&dy,element));
        check(cudaMemcpy(dx,type==0?(void*)x.data():(void*)x16.data(),128*element,cudaMemcpyHostToDevice));
        check(fastllm_packed_int8_cuda::Launch(dx,dw,nullptr,dy,1,128,1,type,false,cudaStreamPerThread));
        check(cudaStreamSynchronize(cudaStreamPerThread));
        float observed; unsigned short raw;
        check(cudaMemcpy(type==0?(void*)&observed:(void*)&raw,dy,element,cudaMemcpyDeviceToHost));
        if(type==1) { __half h; std::memcpy(&h,&raw,2); observed=__half2float(h); }
        if(type==2) { unsigned bits=unsigned(raw)<<16; std::memcpy(&observed,&bits,4); }
        assert(observed==129.0f/131072.0f);
        check(cudaFree(dx)); check(cudaFree(dy));
    }
    check(cudaFree(dw)); check(cudaFree(db));
    std::cout << "PASS: FP32/FP16/BF16, batch1/4/9, bias/residual, exact BF16 scales\n";
}
