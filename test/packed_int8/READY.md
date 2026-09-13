# CPU + loader implementation ready

Native contract accepted and implemented: `PACKED_INT8_GROUP128_BF16=1012`, each group `[128 q+128 uint8 bytes][2 raw BF16 scale bytes]`, logical `[N,K]`, `K%128=0`, row stride `K/128*130`.

## Production files changed
- include/fastllm.h: enum
- include/packedint8.h: native group-interleaved CPU kernel; standalone planar reference and exact-only experimental Q8_0 adapter (NOT selected by loader)
- src/fastllm.cpp: dtype name, size/allocation/group metadata, activation type
- src/model.cpp: shape payload validation for INT4/INT8; native classifier; aux suppression; streamed packed-row loading; public HF prepare/load integration; unsupported formats fail rather than treating I32 as floats
- src/devices/cpu/cpudevice.cpp: native Linear for all F32/F16/BF16 input/output pairs. Weight never dequantized; activation/output scratch only.

## Verified executable evidence
Private remote CPU shared library:
`/home/ai-agent/builds/fastllm-int8-component/build-cpu/tools/ftllm/libfastllm_tools.so`
SHA256 `e8726e02f48554c41d9d49244d2fb3d769b38d151ed1e6376f5976a6814811f0`

- CMake actual `fastllm_tools` CPU build passes.
- Actual Data constructor/allocation/copy/bytes/group metadata pass.
- Actual safetensors + Data loader reads 8 real-row fixtures and preserves all packed/scales bytes.
- Actual shared-library CPU Linear passes all nine input/output dtype pairs per fixture; includes all seven tensors with scales not representable in FP16.
- Public `CreateLLMModelFromHF(... DATA_AUTO_SOURCE ...)` loads small HF real-row fixture as native dtype, logical [1,5120],5200 bytes.
- Actual real model headers/payloads:400 packed weights,400 native INT8 recognized,0 INT4 misclassifications.
- INT4 legacy/symmetric/affine classification regression tests pass.
- Independent scale adapter tested across all32768 nonnegative BF16 encodings (not used at runtime).

Acceptance command (already run successfully):
```
/home/ai-agent/builds/fastllm-test-venv/bin/python /home/ai-agent/builds/fastllm-int8-component/source/test/packed_int8/run_tests.py /home/ai-agent/builds/fastllm-int8-component/source /home/ai-agent/builds/fastllm-int8-component/build-cpu --fixtures /home/ai-agent/builds/fastllm-real-fixtures --model /home/ai-agent/models/qwen38-huihui-abliterated-w8a16-mtp
```

Logs/test runner/production patch: this directory. `acceptance.log` is the final combined run. `native-int8.patch` applies relative to source root (original archive baseline).

## Boundaries / handoff
- CUDA and multicuda files NOT changed here; parent/other agent owns them.
- Full Qwen model forward/GPU inference NOT run; all GPUs occupied. CPU reference kernel is correctness-first, not optimized.
- Disk-lazy, LoRA, transposed-CONV native loading explicitly unsupported.
- Shape-less legacy symmetric I32 remains INT4 for compatibility; shape-bearing INT8 requires exact logical dims and BF16 group128 scales. F32 INT8 scales / padded dimensions / act-order / affine INT8 not supported.
- Export/save and arbitrary reshapes/slicing need separate support review; public HF load + CPU Linear is the verified boundary.
- Existing ErrorInFastLLM waits for input: expected-negative tests use timeout; production error behavior is inherited, not introduced.
