#include "packedint8.h"
#include <cassert>
#include <cmath>
#include <iostream>
#include <vector>
int main() {
 const size_t rows=3,cols=256,batch=2;
 std::vector<uint8_t>w(rows*cols); std::vector<uint16_t>s={0x3e80,0x3f00,0x3381,0x3381,0x3f80,0x4000};
 std::vector<uint16_t>x(batch*cols,0x3c00); // FP16 1
 for(size_t i=cols;i<x.size();i++)x[i]=0xc000; // FP16 -2
 for(size_t r=0;r<rows;r++) for(size_t c=0;c<cols;c++)w[r*cols+c]=static_cast<uint8_t>(c);
 float out[batch*rows]={},bias[rows]={0.5f,0,1};
 fastllm::PackedInt8Group128LinearF16(x.data(),w.data(),s.data(),bias,out,batch,rows,cols);
 for(size_t b=0;b<batch;b++)for(size_t r=0;r<rows;r++) {
   double expected=bias[r];
   for(size_t c=0;c<cols;c++) {
     uint32_t bits=uint32_t(s[r*2+c/128])<<16; float scale; std::memcpy(&scale,&bits,4);
     expected+=(b==0?1.0:-2.0)*(int(c)-128)*scale;
   }
   assert(std::abs(double(out[b*rows+r])-expected)<1e-8);
 }
 bool rejected=false; try { fastllm::PackedInt8Group128LinearF16(x.data(),w.data(),s.data(),nullptr,out,1,rows,255); } catch(const std::runtime_error&) { rejected=true; } assert(rejected);
 std::cout<<"PASS: native W8A16 CPU grouped linear, BF16 subnormal precision, batches, rows, bias, signed offset, invalid shape\n";
}
