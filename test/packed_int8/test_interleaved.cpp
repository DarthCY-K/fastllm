#include "packedint8.h"
#include <cassert>
#include <iostream>
#include <vector>
int main(){
 std::vector<uint8_t>w(520); std::vector<float>x(512,0.1f); float y[4];
 for(int r=0;r<2;r++)for(int g=0;g<2;g++){
  uint8_t*p=w.data()+(r*2+g)*130;
  for(int j=0;j<128;j++)p[j]=static_cast<uint8_t>(g*128+j);
  uint16_t s=r==0?(g==0?0x3e80:0x3f00):0x3381; std::memcpy(p+128,&s,2);
 }
 fastllm::PackedInt8InterleavedLinearF32(x.data(),w.data(),nullptr,y,2,2,256);
 for(int b=0;b<2;b++)for(int r=0;r<2;r++){
  double ref=0;for(int c=0;c<256;c++){int g=c/128;uint16_t s;std::memcpy(&s,w.data()+(r*2+g)*130+128,2);uint32_t bits=uint32_t(s)<<16;float f;std::memcpy(&f,&bits,4);ref+=double(x[b*256+c])*(c-128)*f;}
  assert(std::abs(y[b*2+r]-ref)<1e-4);
 }
 std::cout<<"PASS: group-interleaved runtime layout, native F32 activation, BF16 scale preservation\n";
}
