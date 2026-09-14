# DFlash 尾块≤64 丢种 bug — 完整根因链与修复设计（2026-09-14 调研）

> 关联：AB8《推理机-FastLLM-YaRN对比与尾块行为》、AB7b《参数扫描与草稿失步诊断》。本文件为源码级根因 + 修复草案，供编译前评审。

## 一、症状与证据（全部为实测）

| 场景 | 签名 | 影响 |
|---|---|---|
| 冷启动：prompt 尾块 ≤64 token（AB8：16139=63×256+11；16135=63×256+7） | 无 `long prefill cache seeded` 行 + `[Qwen3.5 MTP] not enabled: draft cache is not aligned with the target cache` | 整回合纯解码 **52 tok/s**（正常 200+，≈4× 损失）+ 前缀不入缓存 |
| 恢复：restore 后 recompute 尾块 ≤64（AB7b：尾 15） | `align mismatch: expected=19982 active=19968 cacheLen=19456 preTokens=527` | 同上（低调 lost） |

触发概率 ≈ **25%**（prompt 长度 mod 256 ∈ [1,64]，即 FASTLLM_QWEN35_FINAL_CHUNK_DECODE_MAX 阈值内），yarn 开/关同样受影响。

## 二、根因链（源码级）

```
qwen3_5.cpp 尾块路径（23375 起，单token解码，注释自证“~20x faster”）
  ├─ MTP 侧（逐token补救，已实现）：
  │    循环内 appendLongPrefillMtpCache() 每 token 喂草稿 KV
  │    + longPrefillMtpSeeded 标志（23436/23499）
  │    + 抑制整块种子（23446-23499 注释块）
  │    + 循环后处理块（23579 else-if 分支）
  └─ DFlash 侧（缺口所在）：
       23395: seedLongPrefillDFlash = false;   ← 直接弃种
       循环内无任何 DFlash 逐token feed      ← 缺失
       注释仅写“per-token decode does not retain the whole chunk's
       hidden states, so the whole-chunk seed is impossible here”
       —— 但没意识到可以像 MTP 那样“逐 token 增量喂”

下一步 decode 时：Qwen35MTPForward 对齐检查（17437-17497）
  activeCacheTokens(19968) != expected(19982)（草稿落后=尾块长度-1）
  → 17475 的“超前截断自愈”带 !useDFlash 守卫（操作对象是 mtpCache.Truncate）
  → DFlash 落入 else：eraseDraftCache() + return false
  → 整个回合禁用投机 + requireMtp 种子不再记录
```

**上游状态**：#731（仍 open）与本仓库同构（同样只有 MTP 补救）；master 连尾块路径都没有（无 finalChunkDecodeSteps）。→ **上游同样存在此 bug；修复属新增工作。**

## 三、修复设计（草案 A：逐 token 增量种子）

在尾块循环内（MTP feed 之后）新增 DFlash 镜像块：

```cpp
if (seedLongPrefillDFlash && onePosPtr != nullptr &&
    !model->speculativeDFlashHiddenStates.empty()) {
    const bool dflashFits = Qwen35DFlashDraftFitsContext(
        model->max_positions, model->dflashCheckpointBlockSize,
        longPrefillBaseTokens + st + t + 1);
    bool oneDFlashAppended = false;
    if (dflashFits) {
        try {
            oneDFlashAppended = appendLongPrefillDFlashCache(
                longPrefillBaseTokens + st + t,          // committedTokens 逐 token 校验点
                1,                                        // 增量单 token
                (t + 1 == curLen) &&
                    !Qwen35DFlashCommitEndsRequest(*model, singleContext, {ret.back()}),
                (t + 1 == curLen) ? (int)ret.back() : -1, // 末 token 生成首批草稿
                longPrefillDFlashDraftTokens);
        } catch (...) { releaseLongPrefillDFlashHidden(); throw; }
    }
    if (!oneDFlashAppended) seedLongPrefillDFlash = false;    // 失败退回现状
    else if (t + 1 == curLen) longPrefillDFlashSeeded = true; // 既有循环后块自动接管
}
```

- 循环后既有块（23557 `if (longPrefillDFlashSeeded)`）**无需改动**：自动注入首批草稿到 `nextInputTokenLists` + 打种子行 + 进入投机。
- 峰值内存：每 token 或尾块结束统一 `releaseLongPrefillDFlashHidden()`（≤64 token，量小）。
- **编译前核对项**：`AppendDFlashTargetHidden`（定义 27559；声明 include/models/qwen3_5.h:484）以 `tokens=1` 增量调用时的 dims 假设；`validLongPrefillDFlashCache` 增量后形状。
- **覆盖**：冷启动 + 恢复两条路径（同一段代码）。

**方案 B（不做）**：对齐检查"落后"case 的通用自愈——需 dflashContext 截断/补种接口（现无）；A 落地后不应再触发。
**加固 C（可选后做）**：17475 守卫的"超前截断"case 为 DFlash 补等价截断（工具调用打断场景，低频）。

## 四、测试计划与预期

1. AB8 复现：16K 双请求（尾 11/7）→ 期望：**无 skip 行、有 seeded 行、decode ~200 tok/s**。
2. 回归：AB5 steady 32K、AB7b 恢复场景、尾块 >64 普通路径、MTP 关闭场景、soak。
3. 收益：命中请求 ~4× decode + 前缀复用恢复；无命中请求零影响。
4. 工作量：补丁 ~40 行、编译、一个测试窗（半天内可闭环）。

## 五、涉及位置

- `src/models/qwen3_5.cpp`：23375-23500（尾块循环）、17437-17497（对齐检查）、23240-23305（append 函数）、27559（AppendDFlashTargetHidden）
- `include/models/qwen3_5.h:484`

## 六、实现与验收（2026-09-14 晚，当日闭环）

**实现**：三处改动（+46/−2，单文件）已提交 merge2 `a794da58`：
1. 尾块循环内新增 DFlash 逐 token 增量块（镜像 MTP；失败优雅退化为旧行为）；
2. 移除尾块入口处的 `seedLongPrefillDFlash = false`（改到循环后统一抑制）；
3. 循环后抑制整块 DFlash 种子（与 MTP 同式）。
**编译**：原始配方 `CPATH=<nvcc nccl include> LIBRARY_PATH=fastllm-link-deps make -j96 fastllm_tools`；新产物 `libfastllm_tools.so` md5 `9c010b441cfc4cf0bcbdeb2ff5c5305c`（生产包 `2d0894a2…`，+224B）；qwen3_5 对象重编无错误。

**AB9 验收（测试窗 18:10:37–18:18:53，prod 停 8.3 分钟，已恢复并验证）**：

| 档位 | 修复后 | 基线(AB8-Y1) | 判定 |
|---|---:|---:|---|
| 2K digits / prose | 215.3 / 72.7 | 214.9 / 72.5 | 平 |
| **16K digits / prose（尾块 11/7）** | **210.9 / 72.1** | 52.1 / 52.0 | **4.05× 修复** |
| 64K digits / prose | 199.6 / 65.6 | 197.4 / 64.5 | 平 |
| 128K digits | 190.5 | 150.3（弱样本） | 正常 |
| 多轮 turn2/turn3 | ~217 / ~214 | turn2 ~51（失配 bug） | **4.25× 修复** |

- 关键指纹：16K 两请求出现 `seeded: tokens=16139/16135`（修复前缺失）；**skip / not aligned / align mismatch 全部为 0**；Traceback 0；计数输出 md5 与修复前完全一致（只恢复投机、不改生成）。
- 制品：`ab9_fix.json`、`ab9_mt.json`、`stack-ab9-fix.log`、`run-ab9.log`（均在 upgrade-test/）。

**转正材料**（已于七节执行）：`switch_to_dflashfix.sh`（备份 venv → overlay-fix 同步 → 重启 → tail64 探针验证，~40s 窗口）；回滚 `rollback_dflashfix.sh`（恢复 `ftllm.backup-20260914-pre-dflashfix`）。

## 七、转正完成（2026-09-14 18:35:48–18:36:38）

- venv 备份 `ftllm.backup-20260914-pre-dflashfix`（616M）→ overlay-fix 同步（160 文件，两侧 md5 = `9c010b44…`）→ 重启 → 探针实测：**16K 尾块 decode 191.7 tok/s**（修复前 52.1；冷启动首请求，测试窗稳态 210.9）+ **`seeded: tokens=16139, chunk=512` 出现**（修复前该行缺失）。
- Gitea：main `18311e92 → a794da58`；tag `dflash-tailfix-prod-20260914`（annotated → a794da58）；基线 bundle `artifacts/DFLASHFIX_BASELINE_20260914.bundle`（22MB）。
- 回滚：`bash scripts/rollback_dflashfix.sh`（~40s）。
