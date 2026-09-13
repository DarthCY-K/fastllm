#pragma once
#include <cstddef>
#include <limits>
#include <stdexcept>
#include <utility>
#include <vector>
namespace fastllm_packed_int8_tp {
struct Copy { size_t dst, src, dstPitch, srcPitch, width, height; };
struct CopyPlan { size_t bytes; std::vector<Copy> copies; };
inline CopyPlan Plan(int rows, int cols, int axis, const std::vector<std::pair<int,int>> &ranges) {
    if(rows<0 || cols<=0 || cols%128 || (axis!=0 && axis!=1))
        throw std::invalid_argument("packed INT8 TP requires [N,K], K aligned to 128, axis 0/1");
    size_t len=0;
    for(auto r:ranges) {
        if(r.first<0 || r.second<r.first || r.second>(axis==0?rows:cols) ||
                (axis==1 && (r.first%128 || r.second%128)))
            throw std::invalid_argument("packed INT8 TP range invalid or not group128 aligned");
        len+=size_t(r.second-r.first);
        if(len>size_t(std::numeric_limits<int>::max())) throw std::invalid_argument("packed INT8 TP shard too large");
    }
    size_t srcPitch=size_t(cols/128)*130;
    size_t dstPitch=axis==0?srcPitch:(len/128)*130;
    CopyPlan p{(axis==0?len:size_t(rows))*dstPitch,{}};
    size_t offset=0;
    for(auto r:ranges) {
        size_t count=size_t(r.second-r.first);
        if(count==0) continue;
        if(axis==0) {
            p.copies.push_back({offset*dstPitch,size_t(r.first)*srcPitch,dstPitch,srcPitch,srcPitch,count});
        } else {
            p.copies.push_back({offset/128*130,size_t(r.first/128)*130,dstPitch,srcPitch,count/128*130,size_t(rows)});
        }
        offset+=count;
    }
    return p;
}
}
