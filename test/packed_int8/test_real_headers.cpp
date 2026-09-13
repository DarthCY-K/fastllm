#include "../../src/model.cpp"
#include <filesystem>
#include <cassert>
int main(int argc,char**argv){assert(argc==2);using namespace fastllm;std::set<std::string>files;
 for(auto &entry:std::filesystem::directory_iterator(argv[1]))if(entry.path().extension()==".safetensors")files.insert(entry.path().string());
 SafeTensors tensors(files);size_t packed=0,native=0,int4=0;
 for(auto &entry:tensors.itmeDict)if(StringEndWith(entry.first,".weight_packed")){
  packed++; native+=TryGetPackedInt8Group128(tensors,entry.first);int g=-1;int4+=TryGetPackedInt4GroupCnt(tensors,entry.first,g);
 }
 printf("real packed=%zu native_int8_group128=%zu misclassified_int4=%zu\n",packed,native,int4);
 assert(packed==400 && native==packed && int4==0);
}
