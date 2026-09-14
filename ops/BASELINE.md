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
