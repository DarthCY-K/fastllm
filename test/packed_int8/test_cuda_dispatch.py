"""Compile-independent dispatch guards; numeric CUDA fixture is separate."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[2]
class Dispatch(unittest.TestCase):
    def test_cuda_routes_native_type_before_activation_specific_paths(self):
        s=(ROOT/'src/devices/cuda/cudadevice.cpp').read_text(encoding='utf-8')
        supported=s.split('bool IsCudaLinearDataTypeSupported(')[1].split('void DoCudaLinear(')[0]
        self.assertIn('PACKED_INT8_GROUP128_BF16',supported)
        linear=s.split('void DoCudaLinear(')[1].split('bool DoCudaLinearAdd(')[0]
        self.assertIn('FastllmCudaMatMulPackedInt8Group128BF16',linear)
        fused=s.split('bool DoCudaLinearAdd(')[1].split('void CudaLinearOp::Run')[0]
        self.assertIn('FastllmCudaMatMulPackedInt8Group128BF16',fused)
    def test_local_packed_metadata_tracks_column_shard(self):
        s=(ROOT/'src/devices/multicuda/fastllm-multicuda.cu').read_text(encoding='utf-8')
        meta=s.split('static void InitMultiCudaLocalTensorMeta(')[1].split('static fastllm::Data *CreateMultiCudaLocalTensor')[0]
        self.assertIn('dst.group = dst.dims[1] / 128',meta)
    def test_cuda_rejects_nondense_views(self):
        s=(ROOT/'src/devices/cuda/fastllm-cuda.cu').read_text(encoding='utf-8')
        wrapper=s.split('void FastllmCudaMatMulPackedInt8Group128BF16(')[1].split('static bool FastllmCudaResolveDataDeviceId')[0]
        self.assertIn('FastllmCudaDataHasDenseStrides(input)',wrapper)
        self.assertIn('FastllmCudaDataHasDenseStrides(output)',wrapper)
    def test_multicuda_uses_verified_byte_plan_on_both_axes(self):
        s=(ROOT/'src/devices/multicuda/fastllm-multicuda.cu').read_text(encoding='utf-8')
        self.assertGreaterEqual(s.count('fastllm_packed_int8_tp::Plan('),3) # upfront validation plus both copies
        self.assertIn('c.dstPitch',s)
        self.assertIn('c.srcPitch',s)
if __name__=='__main__': unittest.main()
