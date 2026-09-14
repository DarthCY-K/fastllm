# FastLLM 推理机生产树（Qwen3.8-27B · ET-FP8 · YaRN 1M · DFlash2）

对象：AI-ReasoningCenter（4×2080Ti 22G，SM75）。本仓库 = 该推理机的 FastLLM 生产源码树 + 部署/验收套件。

## 版本映射（2026-09-14 转正）

- 默认分支 `main` = 生产代码基线：上游 master `21650fa` + 本地补丁（Yarn×DFlash 门控 / packed-int8 / medium 修复）+ PR `#731`/`#732`/`#730`（`git apply --3way` 套用）。
- tag `r2-prod-20260914` → 代码提交 `53ea91f2`（= main 历史的倒数第二个提交，其后仅有 `ops:` 部署套件提交）；该基线对应生产 venv 内 `libfastllm_tools.so` md5 `2d0894a26082360d1d3734bf4b30047a`（123,309,712 B）。
- 盒内路径对应：`~/builds/upgrade-test/repo`；本次推送 `merge2`（= 本仓 main 的源码部分）与 tag。盒内另有 `main`（上游 b9399ac 基线）、`localstate`/`upnew2`/`pr73x` 等中间分支，均为 main 历史的祖先或旁支，未逐一推送。
- 行为指纹（判定引擎版本）：启动后首个长预填的日志 `long prefill cache seeded: tokens=N, chunk=256`（256 = r2 默认快照间隔 2 页下的有效分块；r1 为 512）。

## 部署 / 回滚

- 切换：`ops/deploy/switch_to_upgrade_r2.sh` —— 预检（.so md5 + 4 条 gate 串）→ 备份 venv 包（`ftllm.backup-20260914-pre-r2`）→ `sync_tree.py` 同步 → venv 内 md5/import 复验 → 重启 → 行为指纹探针。
- 回滚：`ops/deploy/rollback_upgrade_r2.sh` —— 一条命令恢复切换前完整包并重启。
- 探针：`ops/deploy/chunk_probe.py`（~2.2K 冷预填验证 chunk=256）。

## 验收材料

- `ops/docs/`：《推理机-FastLLM-r2升级执行记录-2026-09-14》《推理机-FastLLM-r2严谨复测总结-2026-09-14》——含四配置交错复测（现产/默认/16页对照/转正后）与结论。
- `ops/evidence/`：复测原始 JSON、三个测试栈完整日志、生产日志片段、切换日志（**密钥已脱敏 [REDACTED]**）。
- `ops/BASELINE.md`：基线清单（md5/指纹/备份/回滚路径）。
- `ops/bench/`：复测脚本（ab5/ab6 基准、解析器/对比器、snap16 启动器）——可在盒内原样复跑。

## 维护约定

- 后续升级（r3…）：盒内 repo 新分支叠加 → 新 tag（`rN-prod-YYYYMMDD`）→ 推送 `merge2:main` + 新 tag + 追加 ops/ 材料。
- 构建配方与升级工艺见盒内 `~/builds/upgrade-test/` 与本机运维技能库（remote-gpu-inference-ops）。
