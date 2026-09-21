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

## 增补 5：工具调用重复同值参数宽容化（2026-09-15）

- **事件**：00:17 一次长单文件任务的工具块尾部复读了 `path` 参数 → `malformed_tool_block` 整块拒绝（HTML 已完整仍作废）；全日志 3797 条请求中此类 2 次。
- **变更**：`qwen3coder_tool_parser._build_tool_call` 改为「重复且同值 → 忽略重复项；重复且异值 → 仍拒绝」（仅 Python 解析层，不动引擎/采样）。
- **验证**：新增 3 例 RED→GREEN（含 `FunctionCallParser` 门面复刻用例），`test/toolcall` 208 tests OK (skipped=1)；部署件自检 3 项 PASS；00:27:42 重启（PID 74886、~30s、0 Traceback）；401/401/200 + 非流式/流式工具回环 + Pi write/read 落盘核验。
- **备份/回滚**：`qwen3coder_tool_parser.py.wheelbak-20260915-pre-dupparam` → `ops/deploy/rollback_dupparam_lenient.sh`；复现部署 `ops/deploy/apply_dupparam_lenient.sh`。
- **部署件 md5**：`b253557592c542888568f44374a258df`（repo / overlay-fix / overlay-r2 / venv 一致）。
- **依据**：`ops/docs/推理机-工具调用重复参数宽容化-2026-09-15.md`；证据 `ops/evidence/dupparam-20260915/`。

## 增补 6：上游 61c288a9c 合并 + r5 转正（2026-09-16）

- **代码基线**：fork `sm75-2080Ti` @ `e3b65d3b` = 上游 master `61c288a9c` 合并（12 提交，三方自动合并 **0 冲突**）+ r4 carry 提交（issue #726 DFlash 注意力 stream 同步 + PR #663 tool-content 结构化分支）。合并提交 `edd1b29f`（parents `72355e9e` + `61c288a9c`）；回滚 tag `pre-upstream-merge-r5-20260916` → `72355e9e`。
- **上游增量取舍**：对本机（SM75/TP4）有效 = 空头并行卡前缀缓存恢复 `61c288a9`、推理工作区复用/显存预留 `b6efee12`、有界 CUDA 工作区 `d5c2838b`、视觉 TP 四连；**无效** = 双卡预填充加速 `ce7057ba`（官方限定 TP=2 且两卡 SM80/86 eager）、Ampere FP8 marlin 多行 GEMV `15431f65`（SM80/86）、`--mtp_fp8_draft_head` `5f35930a`（本栈 native MTP off）、custom-AR 自检 `ea7965c5`（本栈恒回落 NCCL，且 #739 实测自定义 AR 反慢 12–13%）。#726 上游**仍未修**，carry 补丁继续自带。
- **构建**：`BUILD_OK`（5 分钟，配方同 r3/r4）；产物 `libfastllm_tools.so` **124,515,752 B** md5 `06779c196df5a944c95dd25fde8d491f`；`.so` 指纹 `ALLOW_YARN_WITH_DFLASH=2`、`selector_q=1`、`FASTLLM_TP2_MLP_OVERLAP=1`。源码身份用 `git show HEAD:<path> | sha256sum` 与盒子 `repo-r5` 逐字节对齐（5 文件全一致）。
- **验收**：冒烟窗口（`SMOKE_DONE ready=1 prod=1`，count200 md5 `0785ac9ffdae` 与生产逐字节一致、desync=0、`role=tool`+对象 content → 200）+ 尾块收敛探针全 PASS（tail16 227.2 / tail62 225.9 / control300 213.7，md5 `813902afb70a`）+ 全量 A/B（出现 64K/128K digits「疑似回归」−3.5~4.6%）+ **定向复测推翻该结论**（3 重复 × 输出逐字节对齐：64K cold 1.002 / 64K warm 1.000 / 128K cold 1.007 / 128K warm 1.001；引擎侧 median prodA 199.0 vs r5 200.3；TTFT 持平）。
- **转正**：10:31 `switch_to_r5.sh` → `SWITCH_DONE ready=1 pkg=r5 so=06779c19…`；转正后 post_switch_probe 与尾块探针全 PASS、desync=0、空载显存 17752/16438/16438/16418 MiB。**回滚**：`ftllm.backup-20260916-pre-r5`（617M）+ `ops/deploy/rollback_r5.sh`。
- **仓库**：tag `r5-prod-20260916`；基线 `artifacts/R5_BASELINE_20260916.{bundle(43MB),md}`；`compare/ztxz16:master...sm75-2080Ti` = ahead 18 / behind 0。soak 标签已改 `build=r5+e3b65d3b(upstream61c288a9c)`（`build=` 是硬编码，转正后必须同步改）。
- **依据**：`ops/docs/推理机-FastLLM-r5上游合并-验收记录-2026-09-16.md`；套件与探针 `ops/bench/ab_r5_suite.py`、`ops/bench/ab_r5_focus.py`、`ops/bench/run_ab_r5_focus.sh`、`ops/bench/r5_probe.py`、`ops/bench/r5_extra.py`、`ops/bench/r5_tail_probe2.py`；窗口编排 `ops/deploy/run_smoke_r5.sh`、`ops/deploy/run_tail_r5.sh`；证据 `ops/evidence/r5-20260916/`。
- **新增方法学纪律**：①长上下文 decode 单次采样差不得当回归（≥3 重复 + 输出 md5 逐字节对齐 + prod 两头漂移带）；②接受率随窗口推进单调变化属位置/热效应，不归因构建；③内存探针拆 pass1/pass2（r5 稳态 +4.6 kB/req vs prod 0.6–1.0，待 >1h soak 定性）；④同一 ssh 命令行里 `pkill -f '<script>.sh'` 与 `bash <script>.sh` 并存会自杀，清理与启动必须分次、按 PID 杀。

## 增补 7：NVFP4 写入生产 + 生产 key 轮换（2026-09-16）

- **NVFP4 转正（单变量：只改 argv 的模型路径）**：`results/argv-prod-tp4.json` → `/home/ai-agent/staging/nvfp4-w4a16`（`Qwen3_5ForConditionalGeneration` + `vision_config` + `vision-mtp-bf16.safetensors`，**含视觉**；FP8 包为纯文本）。此前 NVFP4 从未进过生产单元（生产日志 `staging/nvfp4-w4a16` 出现 0 次，一直是 `nvfp4_swap.sh` 的"考试窗切换件"），任何重启都回 FP8。
- **起因**：Pi 输出异常中断 → 引擎日志铁证 `multimodal request failed: Qwen3.5 vision_config is incomplete. (returning an empty response)` → 纯文本生产包 + 客户端仍宣称 `supports_vision`（Pi `input` 含 image、Hermes `supports_vision: true`）→ 同请求继续解码产出多语种乱码。
- **验收**（`SWITCH_NVFP4_DONE probe=1 image=1 ready=35s`）：count200 md5 `0785ac9ffdae` 与 FP8 逐字节一致、decode **269.8**（FP8 230.5，+17%）；图像端到端本地三色 + **经 subapi 中继** orange/blue 全中；尾块 tail16 257.0 / tail62 257.3 / control300 236.1（FP8 227.2/225.9/213.7）、md5 `813902afb70a`、desync=0；显存 16540/15170/15170/15150 MiB（FP8 每卡多 ~1.2–1.3GB）。回滚 `ops/deploy/rollback_prod_nvfp4.sh`；argv 备份 `argv-prod-tp4.json.bak-pre-nvfp4-20260916`。
- **key 轮换 + 明文根因修复**：泄漏点 = `site-packages/ftllm/server.py` 的 `logging.info(args)`（每次重启把 64-hex key 写进日志；全机扫描 **70 个文件**含该 key）。修复 `ops/deploy/apply_nslog_redact.py`（幂等，只改打印对象、不动真实 args）；轮换 `ops/deploy/rotate_prod_key.sh` → `ok=1 new=200 old=401 noauth=401`、`new_key_leaks=0`。env 备份 `qwen38-0.2x.env.bak-pre-rotate-20260916`。
- **中继依赖（坑）**：客户端链路 = Pi → `subapi.kjsygame.com`(156) → **account#13 `DarthCY-Qwen-Local`** → `http://101.43.40.158:11452/v1`。换盒子 key 必须同步该账号 `credentials->>'api_key'`；**只改 DB 不够**——sub2api 有凭据缓存，会拿旧 key 打上游 → 401 → 自动把账号置为不可调度（`account_disabled_auth_error`）→ 客户端 502/503。修法：`fix_account13.sql` 复位 + `systemctl restart sub2api`。
- **历史擦洗**：`ops/deploy/scrub_old_key.py`（同长度就地替换、保持 inode，排除 live 日志/env/备份）→ **68 文件 68 处**已抹；复扫只剩当前 env。**遗留**：live 生产日志 47 处**已失效**旧 key，下次停服务窗口清理。
- **后续**：①`apply_nslog_redact.py` 是 venv 层补丁，**每次升级 ftllm 后必须重跑**；②NVFP4 质量重尾（虾跑分 n=8 中一场 64.7）未排除，建议补同日 n≥3 对照；③本轮新坑：`scp` 端口是 `-P`（`-p` 会报 `stat local "11453"`）。
- **依据**：`ops/docs/推理机-NVFP4转正与密钥轮换-2026-09-16.md`；脚本 `ops/deploy/{switch_prod_nvfp4.sh,rollback_prod_nvfp4.sh,apply_nslog_redact.py,rotate_prod_key.sh,scrub_old_key.py,scan_key_files.py,make_sub2api_key_sql.sh,fix_account13.sql}`；探针 `ops/bench/{nvfp4_image_probe.py,relay_image_probe.py}`；证据 `ops/evidence/nvfp4-rotate-20260916/`。

## 增补：r9b 转正（2026-09-21）
- 生产引擎由 r8（so `1c7fc3f3`）切换为 **r9b**（r9 上游全量合并 + PR#747；so `66f68772abe34a596bbe187addb0451a`）。
- 切换脚本 `ops/deploy/switch_to_r9b.sh`；venv 备份 `ftllm.backup-20260921-pre-r9b`；回滚 `ops/deploy/rollback_r9b.sh`。
- 转正验证：启动门禁行齐（Yarn 允许 / 1M 上下文 / DFlash2 TP prepared）；功能回归检查 ×2 全 PASS（md5 f5de00c5/30f8a5c9ee88/2adaf2269e77 与基线逐位一致；dec 232.2/200.1、237.5/201.9）；产线 tail64=218.5 t/s（seeded=1）；errors=0、desync=0。
- 生产 launcher 未开 SSD 持久前缀（`FASTLLM_PREFIX_CACHE_DIR` 未设，功能休眠）；启用方式见 `docs/qwen35-persistent-prefix-cache.md`。

## 增补：SSD 持久前缀缓存产线启用（2026-09-21 11:30）
- launcher 增 5 行 env（`FASTLLM_PREFIX_CACHE_*`，目录 `/home/ai-agent/prefix_ssd_prod`、quota 64GiB、restore=always），备份 `fastllm_prod_launch.py.bak-pre-ssdprefix-20260921`；**撤销=删块+重启**。
- 产线复验（按 #747 文档流程）：固定 16K 前缀冷跑 11.79s/cached 0 → 提交检查点（停服等待提交 ≤30s 生效，含 14336）→ 重启 → **run2 2.31s/cached 14336、md5 与冷跑一致（6ed2fc28eda2）**；功能回归 ×2 md5 全同基线；errors=0、desync=0；目录 690M/1271 文件。
- 证据：ops/evidence/r9-747-20260921/ssd-prod/。

## 增补：提交署名重写（GitHub 身份归位，2026-09-21）
- 目标：fork 上本机产生的提交统一署名为 **`DarthCY <452710557@qq.com>`**（邮箱与账号 DarthCY-K 关联已核实；上游提交与上游 PR 署名保持原样）。
- 方法（修正版）：**逐字节外科手术**——只重建邮箱命中的 71 个提交/标签对象，其余对象（含上游经 GitHub 网页签名的提交 gpgsig 头）原封保留。
- **教训**：首次误用 `git filter-branch`——其重建会**剥离 GPG 签名**，149+ 个签名提交 SHA 变化并级联 2595 个提交重哈希，与真上游分叉点从 `2236e001` 退至 `cb7d3fcf`（GitHub 显示 2580 ahead / 2556 behind）。已从镜像 `repo-mirror-pre-idfix-20260921.git` 恢复全部 refs 后重做。
- 修正后关键 SHA：重写头 = `a7e82e23`（本节提交前）；tag `r9b-prod-20260921` → `8edb6859`；上游头 `2236e001` 重新成为祖先；树内容逐位不变（diff 为空）；残留旧身份 = 0。
- 仓库 git 身份已设 `DarthCY <452710557@qq.com>`（后续提交自动署名）。

## 增补：r10 转正（2026-09-21 17:07–17:11）
- 生产由 r9b → **r10**（r9b + 上游 7a369c9d 11 提交；so `17586d35f49dc99fc622592d3bc0878a`）。
- 切换脚本 `ops/deploy/switch_to_r10.sh`；备份 `ftllm.backup-20260921-pre-r10`；回滚 `ops/deploy/rollback_r10.sh`。
- 转正验证：门禁行齐；回归 ×2 全 PASS（md5 f5de00c5/30f8a5c9ee88/2adaf2269e77 逐位一致；dec 229.6/200.7、239.9/202.6）；errors=0、desync=0。
- **暖机兜底启用**：重启后由 `ops/deploy/warmup_prod.sh` 吸收 SSD 首请求全量读取校验（本次 96s）→ 用户侧无感。
- 配额 64→16GiB（launcher `.bak-pre-16g-20260921`；约束首请求校验成本上限 ≈55s）。
## 增补：r11 候选链（2026-09-21 晚）——全绿，待转正
- r11 = r10 线 + API key env 加固（`64fc6245`，摘取 maoyufeng1985 `d2f3e937`）+ 上游 `3f1dcc42` 4 提交（merge `b5c45839`）。
- 构建 BUILD_OK：so=`eea71a8fc7a37faca37decb47369db48`；单测 9/9（#747 四项 + NVFP4 回归三项 + 新 MoE 分区；CUDA 两新测试只编不跑；planar 观察项延续）。
- 窗口（19:31–19:34）：三配置 md5 3/3、errs=0、ssd_boot=5、prod 自动恢复。
- 验收（19:36–19:47）：prod 基线（暖机 97s 吸收）md5 3/3、tail64 212.2；cand 3/3、tail64 219.4；308K 针测 found=true 408.6s；seeded=2/desync=0/errs=0。
- 转正物料：`ops/deploy/switch_to_r11.sh` + `rollback_r11.sh`（含暖机）；窗口/验收脚本恢复点已固化暖机。
- 状态：**待转正决策**（转正后推 sm75 + tag）。

## 增补：r11 转正（2026-09-21 20:01）
- 生产由 r10 → **r11**（so `eea71a8fc7a37faca37decb47369db48`）；切换 `ops/deploy/switch_to_r11.sh`；备份 `ftllm.backup-20260921-pre-r11`；回滚 `ops/deploy/rollback_r11.sh`（回 r10，so 17586d35）。
- 转正验证：门禁行齐；暖机吸收 95s；回归 ×2 全 PASS（md5 逐位一致；dec 233.5/197.9、240.0/203.4）；errors=0、desync=0；部署态 so 复核一致。
- 随带上线：API key 环境变量鉴权加固（r11 含）。
- AR 线评估 Step0 结论=不适用（拓扑硬约束），见提案文档文末节。
