# NCCL 初始化通信自检（#734）核验 —— 已随构建入产并静默通过（2026-09-17）

## 结论
上游 PR #734（@zify9000，NCCL 初始化通信自检）内容已于 2026-09-14 以 pick 提交 `3ad12f3d`
入库（当时注记“仅入库，未构建，下次构建携带”），**此后所有构建（r 系 → pooltrim → cont-clamp → mmguard）
均携带该自检**，现役生产 `.so`（md5 `70a04a154e97e158faac1f20a6415065`）内含全部自检逻辑。

## 核验证据
1. `git merge-base --is-ancestor 3ad12f3d a31da590` → **YES**（在主线祖先链内）。
2. 现役 `.so` 字符串含：`NCCL self-test launch failed` / `group launch failed` /
   `mismatch ... expected %f, got %f` / `通信自检失败` 全套（见 `so-selftest-strings.txt`）。
3. 服务日志（98k+ 行、3 天多构建）**零** 自检失败/中止输出（见 `log-selftest-count.txt` = 0）；
   自检设计为失败即 `ErrorInFastLLM` 中止启动——服务正常存活即是自检通过的直接证据。
4. 自检无环境变量开关、随 `FastllmInitNccl` 无条件执行；本机 TP4 + NCCL（LL128）路径必然触发。

## 意义
- 该自检覆盖“`ncclCommInitAll` 成功但集合通信实际不可用/结果错误”的静默降级场景
  （典型诱因：NCCL 与 CUDA 运行时版本不匹配 → TP 各 rank 未归约部分和 → 输出复读/乱码）。
- 与 issue #739（自定义 all-reduce 自检在大消息路径报异常）为不同机制：本次核验确认
  本机 NCCL 路径自检干净；#739 涉及的自定义归约仍有独立守卫（09-13/09-15 修复已在库）。

## 附件
- `so-selftest-strings.txt`：现役 .so 中自检字符串原文
- `pick-commit.txt`：`3ad12f3d` 提交信息与改动统计（+108/-1，与 PR #734 diff 一致）
- `log-selftest-count.txt`：日志中自检失败/中止计数（=0）
- `log-nccl-recent.txt`：日志中 NCCL 相关近期行（初始化正常）
- `deployed-so-md5.txt`：核验时现役 .so 指纹
