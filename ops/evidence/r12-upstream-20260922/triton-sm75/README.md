# r12 先决验证：SM75 Triton chunk GDN prefill 内核编译（2026-09-22）

- 编译器环境：`~/.venvs/fastllm-triton-sm75`（triton==3.2.0 + setuptools），按上游 docs/qwen4.md 指引
- 服务：`tools/fastllm_triton_server.py --host 127.0.0.1 --port 48989`（3.2.0 解释器启动，独立于生产）
- 结果：`triton-sm75-compile.json` —— 4 个内核变体全部编译成功，`sm75_mma=true`（PTX 含 mma.sync），单形状约 2s
- 已验证形状：state=fp32/fp16、chunks=8/65、block_v=32/64（chunk_size=64、k_dim=v_dim=128 固定）
- 结论：SM75 Triton GDN prefill 的编译器先决条件成立
- 边界：varlen/ragged（batched 不等长）路径 gate 仍为 `arch < 80`（cudadevice.cpp:3357，上游未放开）→ Triton 仅覆盖非 varlen 的 chunk 路径（单请求/等长 batch）
- 注意：上游文档明确该路径 prefill 激活 FP16 化，"输出不保证逐位一致"（数值容差 ~1e-4），启用后不能再用 md5 逐位验收
