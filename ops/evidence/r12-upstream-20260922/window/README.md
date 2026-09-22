# r12 冒烟窗口结果（2026-09-22 11:00:14–11:03:26，生产总中断 3 分 12 秒）

候选 so=`4fb02a30c1562e54438846e4c66f014c`（生产 r11 so=`eea71a8f…`）

| 配置 | READY | md5_match | errs | 备注 |
|---|---|---|---|---|
| prod-baseline (8080, 现行 r11) | — | 3/3 | — | dec=232.9 / 200.9 |
| r12-force | ~35s | 3/3 | 0 | dec=226.9 / 200.1 |
| r12-ns | ~30s | 3/3 | 0 | dec=56.2 / 65.3（无投机，正常） |
| r12-ssd | ~35s | 3/3 | 0 | ssd_boot=8（SSD 缓存生效） |
| r12-triton (TRITON_SM75=1) | ~35s | 3/3 | 0 | dec=231.4 / 204.5 |

- 四配置与现场生产基线、历史基线（r8–r11）**逐位一致** → 合并零回归
- 生产恢复：PROD_READY ~35s + warmup 暖机 0s；`prod=1`
- **说明**：triton 配置的短探针 prefill 不足 2 个 chunk，不满足 SM75 Triton gate → 未触发 Triton 路径；该配置输出与默认逐位一致属合理。**Triton 长 prefill A/B 留验收阶段**（tail64 16K / needle 308K）
