# Accepted shared native runtime contract

- DataType::PACKED_INT8_GROUP128_BF16 = 1012.
- Logical dims [N,K], K positive and divisible by128.
- **Group-interleaved** row storage: for each K/128 group, [128 uint8 weights encoding q+128][2 raw little-endian BF16 scale bytes]. Row stride (K/128)*130.
- Every scale and integer preserved bit-for-bit; no FP16 scale conversion.
- CPU loader repacks only (stream each row), CPU linear consumes this layout directly.
- Parent/second agent owns CUDA and multicuda/TP; this agent owns fastllm.h,fastllm.cpp,model.cpp,CPU dispatch and tests.
- Previous standalone header helper accepts planar packed/scales inputs; runtime will use new interleaved helper.
- Existing exact Q8_0 helper is experimental and NOT selected for runtime loading.

Status: CPU Data/loader/Linear wiring built and verified. See READY.md and acceptance.log. CUDA/TP remains owned by parent/second agent.
