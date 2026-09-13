#include "fastllm-multicuda-packed-int8.h"
#include <cassert>
#include <cstring>
#include <iostream>
#include <vector>
using namespace fastllm_packed_int8_tp;
int main() {
    const int rows=5, cols=512;
    std::vector<unsigned char> src(rows*4*130);
    for(size_t i=0;i<src.size();i++) src[i]=(i*31+i/130)%256;
    for(int axis: {0,1}) {
        std::vector<std::pair<int,int>> ranges=axis==0?std::vector<std::pair<int,int>>{{3,5},{0,1}}:std::vector<std::pair<int,int>>{{256,512},{0,128}};
        auto plan=Plan(rows,cols,axis,ranges);
        std::vector<unsigned char> out(plan.bytes,0);
        for(auto &c: plan.copies) for(size_t r=0;r<c.height;r++) std::memcpy(out.data()+c.dst+r*c.dstPitch,src.data()+c.src+r*c.srcPitch,c.width);
        std::vector<unsigned char> expected;
        if(axis==0) for(auto range:ranges) for(int r=range.first;r<range.second;r++) expected.insert(expected.end(),src.begin()+r*520,src.begin()+(r+1)*520);
        else for(int r=0;r<rows;r++) for(auto range:ranges) expected.insert(expected.end(),src.begin()+r*520+range.first/128*130,src.begin()+r*520+range.second/128*130);
        assert(out==expected); // Verifies every raw weight AND scale byte across disjoint/reordered ranges.
    }
    for(auto range: std::vector<std::pair<int,int>>{{1,128},{0,129},{-128,0},{256,128},{0,640}}) {
        bool threw=false; try { Plan(rows,cols,1,{range}); } catch(const std::invalid_argument&) { threw=true; } assert(threw);
    }
    bool threw=false; try { Plan(rows,255,0,{{0,1}}); } catch(const std::invalid_argument&) { threw=true; } assert(threw);
    assert(Plan(rows,cols,1,{{0,0}}).bytes==0);
    std::cout<<"PASS: CUDA TP byte-copy plans, both axes, reordered multirange, BF16 payloads, invalid alignment/ranges, empty shard\n";
}
