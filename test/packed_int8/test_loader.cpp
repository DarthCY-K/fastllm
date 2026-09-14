#include "../../src/model.cpp"
#include <cassert>
namespace fastllm { void DoCpuLinear(Data &, Data &, const Data &, Data &); void Float32ToFloat16(float*,uint16_t*,int); void Float32ToBFloat16(float*,uint16_t*,int); void Float16ToFloat32(uint16_t*,float*,int); void BFloat16ToFloat32(uint16_t*,float*,int); }
int main(int argc,char**argv){
 assert(argc==2); using namespace fastllm;
 SafeTensors st({argv[1]}); const std::string name="x.weight_packed";
 assert(TryGetPackedInt8Group128(st,name));
 assert(IsSafeTensorQuantAuxTensorName(st,"x.weight_scale"));
 assert(IsSafeTensorQuantAuxTensorName(st,"x.weight_shape"));
 auto &item=st.itmeDict.at(name); int cols=int(item.shape[1])*4;
 Data w(DataType::PACKED_INT8_GROUP128_BF16,{int(item.shape[0]),cols});
 LoadPackedInt8Group128Weight(st,name,w);
 std::vector<uint8_t>p(item.bytes);item.ReadRawData(p.data(),p.size());
 auto &s=st.itmeDict.at("x.weight_scale");std::vector<uint8_t>scale(s.bytes);s.ReadRawData(scale.data(),scale.size());
 for(size_t g=0;g<p.size()/128;g++){
  assert(!std::memcmp(w.cpuData+g*130,p.data()+g*128,128));
  assert(!std::memcmp(w.cpuData+g*130+128,scale.data()+g*2,2));
 }
 for(DataType dtype : {DataType::FLOAT32,DataType::FLOAT16,DataType::BFLOAT16}) {
  for(DataType outType : {DataType::FLOAT32,DataType::FLOAT16,DataType::BFLOAT16}) {
  Data input(dtype,{2,cols}), output(outType,{2,1}), bias(DataType::FLOAT32);
  input.Allocate();std::vector<float>x(2*cols);for(int j=0;j<2*cols;j++)x[j]=float(j%7-3)*0.125f;
  if(dtype==DataType::FLOAT32)memcpy(input.cpuData,x.data(),x.size()*4);
  else if(dtype==DataType::FLOAT16)Float32ToFloat16(x.data(),(uint16_t*)input.cpuData,x.size());
  else Float32ToBFloat16(x.data(),(uint16_t*)input.cpuData,x.size());
  DoCpuLinear(input,w,bias,output);
  float result[2];if(outType==DataType::FLOAT32)memcpy(result,output.cpuData,8);
  else if(outType==DataType::FLOAT16)Float16ToFloat32((uint16_t*)output.cpuData,result,2);
  else BFloat16ToFloat32((uint16_t*)output.cpuData,result,2);
  for(int b=0;b<2;b++) {double expected=0,magnitude=0;for(int c=0;c<cols;c++) {
   uint16_t bf;memcpy(&bf,scale.data()+(c/128)*2,2);uint32_t bits=uint32_t(bf)<<16;float sf;memcpy(&sf,&bits,4);
   double term=double(x[b*cols+c])*(int(p[c])-128)*sf;expected+=term;magnitude+=std::abs(term);
  } assert(std::abs(result[b]-expected)<=1e-6*magnitude+1e-9+(outType==DataType::FLOAT32?0:std::abs(expected)*(outType==DataType::FLOAT16?0.001:0.008)+3e-8)); }
  }
 }
 printf("PASS: actual CPU Linear dispatch F32/F16/BF16 native weights vs double reference\n");
 printf("PASS: actual safetensors reader + native Data loader, all packed bytes/scales exact (%zu groups)\n",p.size()/128);
}
