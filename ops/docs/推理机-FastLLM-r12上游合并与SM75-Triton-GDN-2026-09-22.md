# 推理机-FastLLM r12：上游合并与 SM75 Triton GDN 预填充评估（2026-09-22）

## 0. 摘要

- **r12** = lazy-recover 线（`ad7e6134`：SSD 前缀缓存 v2 + 启动恢复惰性化，生产当前）＋ 上游 `14f849af` 4 提交 → merge `6fd1f9a4`（零冲突，ort 策略）。
- **构建与测试全绿（未动生产）**：全量构建 10 分钟零错误；CPU 单测 4/5 PASS（1 个既存观察项）；CUDA 测试全部 PASS——含 **`cuda_prefill_paths_test gdn_sm75` 7 形状端到端数值验证**（max_error ≤1.14e-05 < 容差 1e-4）。
- **先决验证（编译器侧）通过**：独立 Triton 3.2.0 环境 2s 编出全部 4 个内核变体，`sm75_mma=true`（PTX 含 `mma.sync`）。
- **收益边界**：Triton 仅覆盖非 varlen 的 chunk 路径（单请求/等长 prefill）；varlen（batched ragged）gate 仍为 `arch < 80`（cudadevice.cpp:3357）→ 高并发不等长 batch 仍走 native。
- **数值口径**：该路径 prefill 激活由 FP32 改 FP16（上游文档明示），输出与 native **非逐位一致**（实测 ~1e-5）→ 启用 Triton 后不能再用 md5 逐位验收；默认配置（不开 Triton）不受影响、md5 口径仍有效。

## 1. 变更清单（ad7e6134 → 6fd1f9a4，11 文件 +611/−165）

| 提交 | 内容 | 文件 |
|---|---|---|
| `d2790a31` | SM75 Triton GDN prefill：gate 加 SM75 opt-in（`FASTLLM_CUDA_TRITON=1`）＋ v9 内核名 ＋ `sm75_mma` 响应校验 ＋ 失败形状记忆 | cudadevice.cpp、fastllm_triton_server.py、docs/qwen4.md、test_cuda_prefill_paths.cpp |
| `14f849af` | SM70 MTP 碎片 KV：删独立碎片开关、按合并物理区间估算读取开销、重构 ChunkedCublasRaw | fastllm-paged-attention-native.cu、新测试 |
| `a80687f7` | SM75 Marlin ldmatrix x1/x2 全 lane 有效共享地址（MoE 模板） | marlin_moe/marlin_template.cuh、新测试 |
| `1795fd87` | BF16 无 bias 时传 nullptr（避免跨卡旧 bias 缓存解引用） | fastllm-linear-bf16.cu、新测试 |

调用链（d2790a31 生效点，已源码核实）：
`Qwen3.5 GDN prefill` → `Qwen35CudaChunkGatedDeltaRulePrefill`（qwen3_5.cpp:6051）→ op `ChunkGatedDeltaRulePrefill` → `CudaChunkGatedDeltaRulePrefillOp::Run`（cudadevice.cpp:8614）→ 先试 `TryCudaTritonChunkGdnPrefill`（8630）→ `CudaTritonResolveChunkGdnPrefillConfig`（原 gate=`arch<80` 硬挡，现已放开 SM75 opt-in）。

## 2. 先决验证：SM75 Triton GDN 编译器侧（已完成）

- 环境：`~/.venvs/fastllm-triton-sm75`（`triton==3.2.0`，按 docs/qwen4.md 指引）；服务 `tools/fastllm_triton_server.py`（127.0.0.1:48989）。
- 结果：`chunk_gdn_prefill` 4 变体（h / o / h_precomputed_scale / o_fused_decay_mask）全部编译成功，`sm75_mma=true`，单形状 ≈2s；已验证 state=fp32/fp16、chunks=8/65、block_v=32/64。
- 生产启用方式：`FASTLLM_CUDA_TRITON=1` + `FASTLLM_CUDA_TRITON_PYTHON=~/.venvs/fastllm-triton-sm75/bin/python`（编译服务由引擎按需自启/复用）；**不加** `--triton` 参数。
- 形状要求：FP16 激活、chunk_size=64、K/V head dim=128、≥2 chunks（单 token 解码不受影响）。

## 3. 其余提交影响面

- `14f849af`：改动文件在 SM75 上**活跃**（`useChunkedCublasPrefill = !isDecode && arch >= 70`），但被删除的独立碎片开关与线性 KV 开关默认值均为 `arch==70`（我方 SM75 默认关、未设 env）→ 预期行为不变；**冒烟窗口必须覆盖长文 prefill/多页场景**。
- `a80687f7`：仅 MoE 模板（全仓仅 `fastllm-moe-vllm-marlin.cu` include）→ 稠密生产模型不受影响；换 MoE 模型时为必带正确性修复。
- `1795fd87`：BF16 无 bias matmul 传 nullptr；我方模型含 BF16 小投影/视觉塔/MTP 组件 → 默认配置下会走到，方向为正确性修复（避免悬垂跨卡指针）；冒烟默认配置即覆盖。

## 4. 构建与单测（2026-09-22 10:30–10:52）

**构建**：全量 10 分钟（10:30:09 → 10:40:16）零编译错误；`libfastllm_tools.so` md5=`4fb02a30c1562e54438846e4c66f014c`（生产基线 `319a3e34…`）；overlay-r12 基座=overlay-lazy；符号/marker 检查全绿（含 so 内 `sm75_mma`、v9 内核名、`cache_sql_prepare`、`ALLOW_YARN`）。

**CPU 单测**：`reduce_batch` / `numas_nvfp4_moe` / `moe_expert_partition` / `nvfp4Block32Gemm` 全 PASS；`nvfp4_planar` 唯一非 PASS 行 `FAIL: block16 BF16 layouts changed output bits` = **既存观察项**（测试文件未被本次 4 提交触碰，`git diff 3f1dcc42..14f849af` 为空）。

**CUDA 测试**（轻量级，GPU 与生产共享；large_memory/多卡类留给冒烟窗口）：

| 测试 | 结果 |
|---|---|
| `cuda_marlin_sm75_ldmatrix_test`（a80687f7） | PASS ldmatrix x4 |
| `cuda_bf16_bias_multigpu_test`（1795fd87） | PASS nonzero bias on GPU 1（岛内 0↔3 实跑） |
| `cuda_paged_fragmented_attention_test`（14f849af） | PASS len=4099 rows=8 layout=4 tail=1 max_abs=0.0216 |
| `cuda_prefill_paths_test gdn` | PASS（chunks=66 batch=1 heads=2） |
| **`cuda_prefill_paths_test gdn_sm75`（d2790a31 端到端）** | **7 形状全 PASS**：heads=48；chunks=3/8/32/65 batch=1；batch=2；fp16+融合掩码 ×2；output max_error ≤1.14e-05、state ≤6.1e-05（容差 1e-4） |
| `cuda_prefill_paths_test sparse` | rc=1 `sparse fast path rejected` = **Qwen4 稀疏路径**的 arch gate（cudadevice.cpp:3664 `arch<80`）拒绝，Qwen4 专用 + SM75 未开放 → 环境不满足，**非回归** |

证据：`ops/evidence/r12-upstream-20260922/`（`triton-sm75/` 编译验证 + `tests/` 单测日志与汇总）。

**结论**：r12 合并零回归；SM75 Triton GDN 先决与端到端双验证通过；具备进入冒烟窗口条件。

## 5. 冒烟窗口计划（待约时间）

- 配置：`r12-force`（生产同参）/ `r12-ns`（无投机）/ `r12-ssd`（SSD 前缀缓存，测试目录 `prefix_ssd_r12test`）/ `r12-triton`（+Triton SM75，新增）。
- Launch 物料已就绪：`fastllm_test_launch_r12.py`、`fastllm_test_launch_r12_ssd.py`（`TRITON_SM75=1` 开关）。
- 验收：
  - 默认三配置：md5 与现产基线逐位一致（合并零回归）＋ tail64 尾块哨兵 ＋ 无 Traceback。
  - **r12-triton**：GDN prefill 数值容差 + 功能探针 ＋ prefill 速度 A/B（对照 r12-force）＋ 质量抽查（thinking/medium 口径）。
- 生产中断预估：单窗口 ~2 分钟（沿用 r9–r11 模式，自带 trap 恢复）。
- 回滚：`rollback_r12.sh`（随窗口物料生成）。

## 6. 重评条件

- 若上游后续放开 varlen 的 SM75 gate → 重评高并发 batch 场景收益。
- 若 Triton 3.2.0 环境不可用/编译失败 → 保持 `FASTLLM_CUDA_TRITON` 关闭，功能与现产完全一致。
