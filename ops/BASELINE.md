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

## 增补 3：开机自启翻转 + 封版验收（2026-09-14 19:22–19:55）

- **自启翻转**：`enable fastllm-qwen38-tp4` + `disable qwen38-0.2x-tp4`（脚本 `ops/deploy/flip_autostart.sh`）；**重启演练** 19:22:10 发起 → 140s 回线 → fastllm 自动起（PID 1912，SubState=running），旧 vLLM 未起；指纹齐全（1M session / Yarn gate / TP prepared / 0 Traceback）。回退 = 反向 enable/disable。
- **soak v3**：`ops/deploy/soak_watch_v3.sh`；样本新增 `seed=/skip=` 计数（首样本 seed=1256 skip=4）。
- **封版验收（全过）**：
  - 工具回环：`finish=tool_calls, get_weather{city:Beijing}`；
  - 长输出画像：thinking 长输出 3550 tok @134.6 tok/s；32K 上下文长解码 3892 tok @219.9（md5 `fc3292b2e08d`）；
  - **1M 针测**：308,204-token 提示（针深 120K）→ 正确答 `X9J7-QUARTZ-3312`；`seeded: tokens=308216`（>262K 走 YaRN 外推 + 种子缓存正常）；预填 520.7s（均值 ~590 tok/s、尾段 435）；
  - 虾跑分抽查：**86.8/100**（P80、8 科全 95、反思力 95）→ 历史带 84.6–87.8 内、无回归；https://paofen.cocoloop.cn/report/ses_1789386124795_oj5qbq
- **#734 pick**：commit `bbf154bd`（仅入库未构建；下次构建携带）。
- **制品**：`upgrade-test/artifacts/accept-final/`；本地 `hermes/cache/etfp8-ab/r2-20260914/accept-final/`；文档 `ops/docs/推理机-封版验收-2026-09-14.md`。

## 仓库迁移（2026-09-14 晚）

- 原 Gitea 私有仓 `DarthCY/fastllm-qwen38-prod` 已删除（用户决定：fastllm 只在 GitHub 维护）。
- **单一事实源 = GitHub fork `DarthCY-K/fastllm`**：
  - 分支 **`sm75-2080Ti`** = 真实上游血缘（21650fae + 10 笔，ahead=10/behind=0），内容 = 本基线全部；
  - 分支 `sm75-2080Ti-snapshot` = 原组装史（`47db364c`，等价旧 Gitea main）；
  - tags `r2-prod-20260914` / `dflash-tailfix-prod-20260914` / `backboneforce-prod-20260914` 仍指向 snapshot 链（等同内容）。
- 部署机 remote：已移除 `gitea`，保留 `fork`（github）；日常推送 `git push fork sm75-2080Ti`。

## 增补 4：NCCL_PROTO=LL128 转正 + B4 300K（2026-09-14 夜）

- **变更**：生产 launcher 插入 `os.environ['NCCL_PROTO'] = 'LL128'`（23:01:53–23:02:21，PID 63433）。NCCL 实际选中 TREE+LL128（原 auto=RING+LL）
- **备份/回滚**：`fastllm_prod_launch.py.bak-pre-ncclll128-20260914` → `scripts/rollback_nccl_ll128.sh`
- **窗口证据（三窗 21:56–23:00；8 LL128 栈 vs 6 基线栈，含 b3 连续三连跑控制）**：c32 预填 ttft 34.0→29.1s（−14.4%）；c64 67.9→59.7s（−12.0%）；decode 不变（232.9–237.7 vs 229.4–235.2）；输出 md5 全同
- **B4（转正后，295K）**：294,758-token count 任务 ttft 452.0s（预填均值 652 tok/s）、decode 169.1 tok/s、md5 `0785ac9ffdae`；同日志对照转正前针测（308,216 tok、518.9s、594 tok/s）：逐位置 +4~13%，全程均值 **+10.2%**
- **假象排除**：`NCCL_DEBUG=INFO`+`SUBSYS=INIT,TUNING` → decode 期日志洪泛（935K 行/6min）→ decode 假摔 ~120（W1r/W1D 复现）；与配置无关
- **候选未转正**：chunk2048+间隔16（c32 −10.5%、c64 −5.6%、decode 低 1–2% 观察）；retention 2/4/8 无差异
- **依据**：`ops/docs/推理机-NCCL预填保留扫描-2026-09-14夜.md`；证据 `ops/evidence/nccl-night-20260914/`
