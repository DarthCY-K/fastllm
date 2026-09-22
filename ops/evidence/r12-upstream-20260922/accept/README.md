# r12 验收套餐结果（2026-09-22 11:10:03–11:26:40）

| 阶段 | md5 | tail64 ttft/total/decode (16K) | needle 308K | errs |
|---|---|---|---|---|
| A: prod 基线 (r11, 8080) | 3/3 | 12.512s / 14.813s / 222.6 t/s | — | — |
| C: r12 候选 (8081) | 3/3 | 13.276s / 15.634s / 217.2 t/s | 410.1s found=true | 0 |
| D: r12-triton (TRITON_SM75=1) | 3/3 | 14.118s / 16.475s / 217.3 t/s | **403.5s found=true** | 0 |

- 候选栈指纹：seeded=2 / desync=0 / accept=[100%,98.4%…95.3%] / errs=0；gate/yarn 指纹正常（1M 门控 + DFlash 放行）
- **Triton 生效硬证据**：停掉 :48989 后引擎自动 spawn 编译服务（PID 40826 = `~/.venvs/fastllm-triton-sm75/bin/python overlay-r12/ftllm/fastllm_triton_server.py --host 127.0.0.1 --port 48989`）
- **Triton 收益**：308K prefill 403.5s vs 410.1s = **+1.6%**；16K tail64 无收益（单测噪声 ≈6%）；短探针 md5 全同、needle 双路 found=true
- 结论：Triton 路径正确性成立、小幅正收益（噪声边缘）；默认配置零回归
- 生产恢复：11:26:09 起，PROD_READY ~35s，暖机 0s，prod=1
