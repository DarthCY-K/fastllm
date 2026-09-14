# r2 生产基线清单（FastLLM @ AI-ReasoningCenter）

- **切换时间**：2026-09-14 14:43:38–14:44:12（switch-r2.log），生产中断 ~30s（重启等待）
- **分支/提交**：repo `merge2` HEAD `53ea91f2`（PR #730 → #732 → #731 → merge `85488739`），tag：`r2-prod-20260914`
- **组成**：master 21650fa + 本地（Yarn×DFlash 门控 / packed-int8 / medium 修复） + PR #731/#732/#730（git apply --3way）
- **引擎**：`libfastllm_tools.so` md5 `2d0894a26082360d1d3734bf4b30047a`（123,309,712 B）
  - gate 指纹：ALLOW_YARN_WITH_DFLASH=2、FINAL_CHUNK_DECODE_MAX=1、AUTOWARMUP_SPARE_KV_MB=1、SNAPSHOT_INTERVAL_PAGES=1
  - python 层：`fastllm_completion.py` sha256 `63c57054d8c1782f2acbde1d71f9f6192971aa47f18364232fbdd47152ba483e`（default_effort=2）
- **行为指纹**：probe 200/`SWITCH_R2_OK`；`long prefill cache seeded: tokens=2117, chunk=256`（r2 默认 2 页间隔 → 有效分块 256）
- **备份（可回滚）**：
  - `venv/.../ftllm.backup-20260914-pre-r2`（= r1 生产包 629M）→ 回滚脚本 `scripts/rollback_upgrade_r2.sh`
  - `venv/.../ftllm.backup-20260914-pre-57ecd5a`（更早备份，保留）
- **验收数据**：ab5/ab6 四配置严谨复测（见桌面《推理机-FastLLM-r2严谨复测总结-2026-09-14.md》与 `upgrade-test/ab5_* ab6_*`）
- **未决/风险**：#726（DFlash stream sync）上游开放；#731 尾块路径未实测触发；q1 散文 temp0 跨配置差异（观察项）
- **bundle**：`fastllm-r2-prod-20260914.bundle`（repo --all，含 r2-prod-20260914 tag）

## 增补 1：DFlash 尾块修复转正（2026-09-14 18:35:48–18:36:38）

- **引擎**：`libfastllm_tools.so` md5 `9c010b441cfc4cf0bcbdeb2ff5c5305c`（123,309,936 B，+224B）
- **提交**：`a794da58`（单文件 +46/−2：尾块≤64 逐 token DFlash 种子，镜像 MTP 模式）；tag：`dflash-tailfix-prod-20260914`
- **备份**：`venv/.../ftllm.backup-20260914-pre-dflashfix`（616M）→ `scripts/rollback_dflashfix.sh`
- **验收**：16K 尾块档 decode 52.1→210.9 tok/s（测试窗）；转正探针 191.7 + `seeded: tokens=16139, chunk=512` 出现；多轮 turn2 51→217；输出 md5 不变
- **文档**：`ops/docs/推理机-FastLLM-DFlash尾块丢种bug-修复设计-2026-09-14.md`

## 增补 2：DFlash backbone TP force 转正（2026-09-14 19:11:37–19:13:00）

- **变更**：生产 launcher 第 27 行 `FASTLLM_CUDA_DFLASH_TP_BACKBONE` `auto → force`（draft backbone TP 分片：5 paired MLPs / 10 weights / 2.49 GiB logical / FP16 shards）
- **备份**：`fastllm_prod_launch.py.bak-pre-backboneforce-20260914` → `scripts/rollback_backboneforce.sh`
- **验证**：重启后 `TP prepared: 5 paired MLPs ...`（prod 日志行号 84551，其后无 skipped）；d200 233.4/233.4、c32 解码 222.1（对照无 force 带 220.3–225.7 / 209.0–212.6）；输出 md5 不变（`dacc241c7db8`/`b536474ba172`）；1M 上下文保持
- **依据**：`ops/docs/推理机-FastLLM-开关扫描-2026-09-14.md`（11 配置扫描，唯一赢家，窗口 +7.6~7.9%）
- **其他扫描结论**：fused/MTP 关闭项全部落 ±2% 噪声带（保持默认全开）；DFlash2 checkpoint `block_size=8` = 草稿块上限；chunked_prefill_size 已为 512
