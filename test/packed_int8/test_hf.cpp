#include "model.h"
#include <cassert>
#include <iostream>
int main(int argc,char**argv){assert(argc==2);using namespace fastllm;SetThreads(2);
 auto model=CreateLLMModelFromHF(argv[1],DataType::DATA_AUTO_SOURCE,-1,true,"","",true);
 bool found=false;for(auto &entry:model->weight.weight){auto &w=entry.second;
  std::cout<<entry.first<<" dtype="<<GetDataTypeName(w.dataType)<<" bytes="<<w.GetBytes()<<std::endl;
  if(w.dataType==DataType::PACKED_INT8_GROUP128_BF16){found=true;assert(w.dims==std::vector<int>({1,5120}));assert(w.GetBytes()==5200);assert(w.cpuData);}
 }assert(found);std::cout<<"PASS: public HF model factory auto preserves native packed INT8 weight\n";
}
