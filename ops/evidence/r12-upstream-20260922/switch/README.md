# r12 转正记录（2026-09-22 11:54:28–11:55:24）

- 生产 so: 319a3e34…（r11）→ **4fb02a30c1562e54438846e4c66f014c**（r12）
- 转正脚本 wt-r12/ops/deploy/switch_to_r12.sh；回滚 rollback_r12.sh（恢复 so + launcher）
- launcher 补丁：fastllm_prod_launch.py 增加 SM75 Triton 块（备份 .bak-pre-r12-triton-20260922）
  - 启动日志：`[prod-launch] SM75 Triton GDN prefill ENABLED (python=~/.venvs/fastllm-triton-sm75/bin/python)`
- 回归 run1/run2：md5 全中（f5de00c5/30f8a5c9ee88/2adaf2269e77），dec 233.8/238.7 t/s，errors_since_restart=0
- **Triton 生效验证**：tail64 探针（16K prefill，ttft=12.741s）后引擎自动拉起编译服务（PID 47556 = 3.2.0 python + 生产 overlay），探针 md5 全中
- 生产日志 MTrace = 常态内存追踪（big-grow），非错误（累计 101900 行）
- 生产真实流量长 prefill 实测（31430 tokens）：1165–1360 t/s，DFlash seeded 正常
