# DFlash 注意力 stream 同步守卫（上游 issue #726 对应修复）核验 —— 已在产（2026-09-17）

## 结论
上游 issue #726 所述根因（`FastllmCudaDFlashAttention` 内核经 `cudaStreamPerThread` 发射、
读写共享借用的临时缓冲，归还点前只有 `cudaPeekAtLastError()`、无 stream 同步 →
极小概率 `cudaErrorIllegalAddress` / Xid 13）在本机**已有对应修复并在产**：

- 引入提交：`e3b65d3b`（2026-09-16 08:46，「carry r4: DFlash 注意力 stream 同步…」，
  attention.cu +7 行；同一提交还携带 PR #663 tool-content 结构化小修）。
- 修复内容：`FastllmReleaseCudaTempBuffer` 归还前执行
  `cudaStreamSynchronize(cudaStreamPerThread)`（见 fix-code-excerpt.txt）。
- 祖先链：`git merge-base --is-ancestor e3b65d3b a31da590` → **YES**（主线）。
- 现役生产源码 `repo-r5` 文件核验含该修复（`repo-r5-check.txt`）→
  **现役 .so（70a04a154e97e158faac1f20a6415065）携带该守卫**。

## 现场计数（3 天多、90+ 次服务启动、混合负载）
- 服务日志 `Xid|illegal|Out Of Range|cudaErrorIllegalAddress` 计数 = **0**
- 内核 `dmesg | grep -ci Xid` = **0**
（`incident-counts.txt`；与 issue #726 评论区本机记录一致。）

## 说明
- 上游 issue #726 仍 OPEN（上游未合修复）；本机为「本地先修」等价版本，方向与 issue 建议一致。
- 后续观察：若再出现 Xid13 类崩溃，下一候选路径 = tempo 缓冲改 event 依赖/独立流；
  当前无需行动。本项与 #734 NCCL 自检互不相关（一为草稿注意力缓冲同步，一为集合通信自检）。
