# 实验进度

## 当前已完成的实验

### binder 句柄失效实验 

详细结果： [docs/binder句柄失效实验/experiment-report-2025-02-19.md](docs/binder%E5%8F%A5%E6%9F%84%E5%A4%B1%E6%95%88%E5%AE%9E%E9%AA%8C/experiment-report-2025-02-19.md)

实验设计： [docs/binder句柄失效实验/PLAN.md](docs/binder%E5%8F%A5%E6%9F%84%E5%A4%B1%E6%95%88%E5%AE%9E%E9%AA%8C/PLAN.md)

- 采用 ReDroid 作为 Android 容器环境
- Docker Commit 快照方式能正常进行，但 CRIU checkpoint/restore 失败
    - 原因是 Docker Commit 只保存文件系统信息，没有保存进程的运行状态，所以会自动重新建立新的 Binder 连接，导致 Binder 句柄失效问题无法复现。
    - CRIU 失败的原因是 ReDroid 容器的复杂挂载结构（cgroup, overlayfs, /proc, /sys 嵌套）导致 CRIU 无法正确 checkpoint 进程状态。这个问题与 Binder 无关，是一个已知的 CRIU 阻塞问题。

## 计划中的实验

### 采用 CRIU checkpoint/restore 复现 Binder 句柄失效，并设计内核 ioctl 方案实现 Binder 状态的 dump/restore。

详细计划：[PLAN.md](PLAN.md) 

> 当前的计划涉及修改 linux 内核代码？会不会过于复杂了？

计划存在的问题：[PLAN-ISSUES.md](PLAN-ISSUES.md)

首先要解决的问题：让 CRIU 能成功 checkpoint 一个 Android 容器（目前因为 binder 无关的原因失败，需要进行修复）

计划采用 LXC + CRIU 的方案 (不使用 ReDroid)，以简化容器环境. 参考：[PLAN-ISSUES-SOLUTIONS.md](PLAN-ISSUES-SOLUTIONS.md)。