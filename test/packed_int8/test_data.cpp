#include "fastllm.h"
#include <cassert>
#include <cstring>
#include <iostream>
int main() {
 using namespace fastllm;
 Data w(DataType::PACKED_INT8_GROUP128_BF16,{2,256});
 assert(w.GetBytes()==520); w.Allocate(); assert(w.expansionBytes==520);
 std::memset(w.cpuData,0x81,520);
 Data copy(w); assert(copy.GetBytes()==520); assert(copy.expansionBytes>=520);
 assert(std::memcmp(copy.cpuData,w.cpuData,520)==0);
 assert(w.groupCnt==128 && w.group==2);
 assert(GetDataTypeName(w.dataType)=="packed_int8_group128_bf16");
 std::cout<<"PASS: actual Data allocation, size, copy, group metadata, type name\n";
}
