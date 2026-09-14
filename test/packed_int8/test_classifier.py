"""Compile actual private loader classifiers in a small metadata-only harness.
No model weights or GPU allocation; ReadRawData is extracted verbatim too.
Usage: python3 test_classifier.py /path/to/source
"""
import pathlib, subprocess, sys, tempfile
root = pathlib.Path(sys.argv[1])
src = (root / 'src/model.cpp').read_text()
def function(name):
    start = src.index('    static ' + ('void ' if name.startswith('Validate') else 'bool ') + name + '(')
    pos = src.index('{', start)
    depth = 1
    end = pos + 1
    while depth:
        depth += (src[end] == '{') - (src[end] == '}')
        end += 1
    return src[start:end]
read = src[src.index('        void ReadRawData('):src.index('        // compressed-tensors\' asymmetric')]
prefix = r'''
#include <map>
#include <string>
#include <vector>
#include <cstring>
#include <climits>
#include <cstdint>
#include <cstdio>
#include <stdexcept>
#include <iostream>
#include <cassert>
void AssertInFastLLM(bool b, const std::string &s) { if (!b) throw std::runtime_error(s); }
struct SafeTensorItem {
 std::string dtype, tensorName, fileName;
 std::vector<uint64_t> shape, data_offsets;
 uint64_t bytes=0, len=0;
'''
post = r'''
};
struct SafeTensors { std::map<std::string,SafeTensorItem> itmeDict; };
bool StringEndWith(const std::string&a,const std::string&b){return a.size()>=b.size()&&a.compare(a.size()-b.size(),b.size(),b)==0;}
std::string FindSafeTensorScaleTensorName(const SafeTensors&,const std::string&n){return n.substr(0,n.size()-strlen(".weight_packed"))+".weight_scale";}
'''
main = r'''
int main() {
 SafeTensors s;
 auto &w=s.itmeDict["x.weight_packed"]; w.dtype="I32"; w.shape={10240,1280}; w.bytes=10240ULL*1280*4;
 auto &sc=s.itmeDict["x.weight_scale"]; sc.dtype="BF16"; sc.shape={10240,40}; sc.len=10240ULL*40;
 auto &sh=s.itmeDict["x.weight_shape"]; sh.dtype="I64"; sh.shape={2}; sh.len=2; sh.bytes=16; sh.fileName="shape.bin"; sh.data_offsets={0,16};
 int64_t shape[2]={10240,5120}; FILE*f=fopen("shape.bin","wb"); fwrite(shape,8,2,f); fclose(f);
 assert(TryGetPackedInt8Group128(s,"x.weight_packed"));
 int group=-1; bool wrong=TryGetPackedInt4GroupCnt(s,"x.weight_packed",group);
 if(wrong) { std::cerr << "FAIL: W8 [10240,5120] classified INT4 group=" << group << "\n"; return 1; }
 auto &zero=s.itmeDict["x.weight_zero_point"];zero.dtype="I32";zero.shape={1280,40};zero.bytes=1280ULL*40*4;
 assert(!TryGetPackedAffineInt4GroupCnt(s,"x.weight_packed",group));
 s.itmeDict.erase("x.weight_zero_point");
 shape[1]=10240; f=fopen("shape.bin","wb"); fwrite(shape,8,2,f); fclose(f);
 assert(TryGetPackedInt4GroupCnt(s,"x.weight_packed",group) && group==256);
 auto &z=s.itmeDict["x.weight_zero_point"];z.dtype="I32";z.shape={1280,40};z.bytes=1280ULL*40*4;
 assert(TryGetPackedAffineInt4GroupCnt(s,"x.weight_packed",group) && group==256);
 assert(!TryGetPackedInt8Group128(s,"x.weight_packed"));
 s.itmeDict.erase("x.weight_zero_point");
 s.itmeDict.erase("x.weight_shape");
 assert(TryGetPackedInt4GroupCnt(s,"x.weight_packed",group) && group==256);
 std::cout << "PASS: W8 rejection, shape-bearing INT4, legacy INT4\n";
}
'''
extra = ''
if 'static bool PackedShapeMatches' in src:
    extra = function('PackedShapeMatches')
assert 'static bool TryGetPackedInt8Group128(' in src, 'Native group128 INT8 classifier is missing'
code = prefix + read + post + extra + function('TryGetPackedInt8Group128') + function('TryGetPackedInt4GroupCnt') + function('TryGetPackedAffineInt4GroupCnt') + main
with tempfile.TemporaryDirectory() as d:
    p=pathlib.Path(d); (p/'test.cpp').write_text(code)
    subprocess.run(['g++','-std=c++17','-Wall','-Wextra','-Werror',str(p/'test.cpp'),'-o',str(p/'test')],check=True)
    sys.exit(subprocess.run([str(p/'test')],cwd=d).returncode)
