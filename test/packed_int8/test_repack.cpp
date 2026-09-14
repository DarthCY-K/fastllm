#include "packedint8.h"
#include <cassert>
#include <cstring>
#include <iostream>
int main() {
 uint8_t packed[256]; for(int i=0;i<256;i++) packed[i]=static_cast<uint8_t>(i);
 uint16_t scales[2]={0x3e80,0x3f00}; // 0.25, 0.5 BF16
 uint8_t out[272]={};
 fastllm::RepackPackedInt8Group128ToQ8_0(packed,256,scales,2,out,272);
 for(int b=0;b<8;b++) {
   uint16_t h; std::memcpy(&h,out+b*34,2); assert(h==(b<4?0x3400:0x3800));
   for(int j=0;j<32;j++) assert(static_cast<int8_t>(out[b*34+2+j])==b*32+j-128);
 }
 assert(fastllm::PackedInt8ExactHalfScale(0x3380)==1); // 2^-24, exact subnormal
 bool rejected=false; try { fastllm::PackedInt8ExactHalfScale(0x3381); } catch(const std::runtime_error&) { rejected=true; } assert(rejected);
 uint16_t badScales[2]={0x3e80,0x3381}; std::memset(out,0x55,sizeof(out));
 rejected=false; try { fastllm::RepackPackedInt8Group128ToQ8_0(packed,256,badScales,2,out,272); } catch(const std::runtime_error&) { rejected=true; } assert(rejected);
 for(auto byte:out) assert(byte==0x55); // Reject before mutating destination.
 std::cout << "PASS: exact Q8_0 layout, FP16 subnormals, nonrepresentable rejection without partial writes\n";
}
