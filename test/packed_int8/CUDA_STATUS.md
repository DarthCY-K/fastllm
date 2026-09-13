# CUDA integration handoff (contract accepted)

CUDA consumed CONTRACT.md unchanged: enum1012, interleaved 128 unsigned-offset weights + 2 raw LE BF16 bytes, row bytes K/128*130.

Implemented CUDA FP32/FP16/BF16 activation dispatch, fused bias+residual with FP32 accumulators, native per-thread stream kernel, no INT8 activation quantization or weight cache. Current correctness-first kernel covers arbitrary batches (including MTP); no large-batch GEMM specialization/performance claim.

TP implementation uses a host-tested byte-copy plan for both axes, preserving all raw scale bytes through reordered/disjoint ranges, validates group alignment before CUDA allocation, and keeps bias only on root for column-reduce as existing runtime does.

**Loader/parent coordination:** `Data::UpdateUnitSize()` currently rejects packed dims[K=0], so empty column shards remain unsupported by Data even though the byte-plan handles empty ranges. Either allow K=0 for empty runtime shards (while loader enforces positive source K), or reject configurations allocating no groups to a GPU. Do not silently reinterpret empty packed shards as another dtype. No edits outside CUDA/multicuda ownership made here.

Four changed translation units compiled independently on AI-ReasoningCenter using CUDA12.8/G++13, SM75, O0; separate directory `/home/ai-agent/builds/packed-int8-cuda-agent` (parent build not touched). Baseline warnings only. First compile needed NCCL include from `fastllm-test-venv/lib/python3.13/site-packages/nvidia/nccl/include`.

Tests: CUDA fixture missing-header RED then SM75 compile GREEN; default executable does not call CUDA. TP test missing-header RED then host byte-copy assertions GREEN. Python dispatch guards RED then GREEN. Actual `IsCudaLinearDataTypeSupported` linked from baseline CUDA device object rejects enum1012 (RED exit1), current object accepts all three activations and rejects unsupported bias/input (GREEN exit0).

GPU numeric execution, actual device TP copies/reduction, CUDA graph replay, MTP/full model and throughput remain UNRUN due production GPU occupancy. Parent can run `/home/ai-agent/builds/packed-int8-cuda-agent/test_cuda_packed_int8 --run` only after permission/safe GPU reservation.
