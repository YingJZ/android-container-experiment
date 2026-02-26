## PLAN.md 正确性分析与修正执行计划

### 总体判定：**方案方向正确，但不具备直接可实施性**
PLAN.md 正确地识别了核心问题（Binder 状态存在于内核空间，用户态无法保存），提出的 kernel ioctl dump/restore 思路理论上可行。但存在 **1 个前置阻塞问题**、**3 个致命错误**、**5 个重大遗漏**，按当前描述无法实现。

### 一、前置阻塞问题（Plan Killer）

| # | 问题 | 详情 |
|---|------|------|
| P0 | CRIU 根本无法 checkpoint Android 容器 | 项目自己的实验报告 (experiment-report-2025-02-19.md) 已证明：CRIU 因 Android 容器复杂的挂载结构（cgroup, overlayfs, /proc, /sys 嵌套）而失败。失败原因不是 Binder，而是 mount namespace。 在 CRIU 无法完成基础 checkpoint 的情况下，添加 Binder 支持毫无意义。PLAN.md 完全没有提及这个已知的阻塞问题。 |

结论：任何 Binder C/R 工作都必须以 "CRIU 能成功 checkpoint/restore 该容器" 为前提。这应该是 Phase 0。

### 二、致命错误（Must Fix — 会导致实现失败）

| # | 错误 | PLAN.md 声称 | 实际情况 |
|---|------|-------------|---------|
| E1 | BINDER_FREEZE 不存在 | "利用 Android 11+ 内核的 BINDER_FREEZE" | 项目使用 kernel 5.4.0，BINDER_FREEZE 是 kernel 5.10+ 才引入的。grep 确认 5.4.0 源码中零匹配。没有冻结机制就无法安全地 dump 状态——dump 期间的并发事务会导致数据不一致或死锁。 |
| E2 | ServiceManager 内核空间查找不可行 | "find_service_node_by_name() 在内核中查找服务" | ServiceManager 的名称→handle 注册表完全在用户空间 (servicemanager 进程)。Binder 驱动只知道 context_mgr_node（一个特殊节点），不维护任何名称映射。PLAN.md 提出的 find_service_node_by_name() 函数在内核中根本不可能实现。 |
| E3 | 缺少静默 (quiesce) 机制 | 未提及 | dump/restore 必须在零在途事务 (in-flight transactions)、空 todo 队列、无未决死亡通知的状态下执行。否则 rb-tree 遍历和链表操作会与并发的 binder_thread_read/write 产生竞争条件或死锁。PLAN.md 没有设计任何静默屏障。 |

### 三、重大遗漏（Should Fix — 会导致 restore 后崩溃或状态错误）

| # | 遗漏 | 影响 |
|---|------|------|
| G1 | binder_node 关键字段缺失 | has_strong_ref, pending_strong_ref, has_weak_ref, pending_weak_ref (引用计数状态位), accept_fds, txn_security_ctx, min_priority 均未包含在 binder_frozen_node 中。restore 后节点引用计数不一致会导致 node 被错误释放或泄露。 |
| G2 | binder_ref 死亡通知缺失 | binder_ref_death 指针仅在 "挑战" 章节提及，但未纳入冻结结构。death notification 是 Android framework 的关键机制（linkToDeath/unlinkToDeath），缺失会导致应用收不到服务死亡回调。 |
| G3 | binder_proc 状态不完整 | 缺少 max_threads, requested_threads, requested_threads_started（线程池管理）、context（binder 上下文）、is_dead、deferred_work。线程池参数错误会导致 binder 线程无法正确 spawn。 |
| G4 | binder_alloc 恢复过于简化 | PLAN.md 认为 "mmap + ioctl 就能恢复"。实际上 binder_mmap() 会创建完整的 binder_alloc 内部结构（free buffer list、pages 数组、buffer rb-tree）。如果 checkpoint 时有未完成的 buffer 分配（transaction reply 未处理），简单 re-mmap 会导致 buffer 地址失效。 |
| G5 | 跨进程协调缺失 | Binder 节点是跨进程共享的——一个 node 存在于 server proc 中，ref 存在于多个 client proc 中。PLAN.md 按单进程描述 dump/restore，但实际需要原子性地恢复整个 binder context 中的所有进程，且恢复顺序必须是：ServiceManager → 系统服务（server nodes）→ 应用进程（client refs）。 |


### 四、次要问题（Nice to Fix）

| # | 问题 | 说明 |
|---|------|------|
| M1 | debug_id 未保存 | 不影响功能，但影响调试。建议保留以便 restore 后的 /proc/binder/ 输出可与 dump 前对应。 |
| M2 | ioctl 编号跳跃 | 现有最后编号 'b', 13，提议 'b', 20-21。功能上没有冲突，但惯例上应连续分配 ('b', 14-15)。 |
| M3 | 时间线不切实际 | "每阶段 2-3 周" 对于内核开发 + CRIU 集成 + 跨进程并发调试不现实。Oracle 评估为 "months, not weeks"。 |

### 五、PLAN.md 中正确的部分

| 方面 | 评价 |
|------|------|
| 问题识别 | ✅ 正确识别了 Binder 状态在内核空间、用户态 checkpoint 无法保存的根因 |
| ioctl 方案方向 | ✅ 通过 kernel ioctl 导出/导入状态是业界公认的正确方向（Flux 论文也采用类似思路） |
| 恢复顺序概念 | ✅ "先恢复 server nodes，再恢复 client refs" 的顺序正确 |
| ioctl 编号无冲突 | ✅ 'b', 20-21 与现有 ioctl 无冲突 |
| 冻结结构基本骨架 | ✅ binder_frozen_node/ref/thread/fd 的基本字段（ptr, cookie, desc, strong, weak）是正确的起点，只是不完整 |
| CRIU protobuf 集成思路 | ✅ 新增 protobuf image format + fd 检测 + dump/restore 路径的架构设计合理 |

### 六、修正后的执行计划

#### Phase 0: 解决 CRIU 前置阻塞（预计 4-6 周）

目标：让 CRIU 能成功 checkpoint/restore 一个 Android 容器（可以是简化版）

| 步骤 | 任务 | 交付物 |
|------|------|--------|
| 0.1 | 分析 CRIU 失败日志，分类所有 mount/cgroup/overlayfs 失败点 | 失败点清单 |
| 0.2 | 构建最小 Android 容器（精简 mount 结构，去掉 CRIU 不支持的挂载类型） | 可 checkpoint 的最小容器 |
| 0.3 | 或者研究 CRIU 的 --ext-mount-map / --manage-cgroups 选项绕过挂载问题 | CRIU 配置方案 |
| 0.4 | 验证：CRIU checkpoint → restore 成功（进程存活，但 Binder 预期失效） | Gate check: CRIU C/R 可工作 |

不通过 Gate check 则后续所有阶段无意义。

#### Phase 1: Binder 静默 (Quiesce) 机制（预计 3-4 周）

目标：实现 Binder 冻结屏障，保证 dump 时状态一致

| 步骤 | 任务 | 详情 |
|------|------|------|
| 1.1 | 实现 BINDER_FREEZE ioctl（backport 或自研） | 停止新事务进入，drain 所有 workqueue，等待 todo 链表清空 |
| 1.2 | 实现 BINDER_UNFREEZE ioctl | 恢复正常事务处理 |
| 1.3 | 添加 "stable state" 检查 | dump 前验证：todo 为空、无 pending transaction、无 outstanding buffer |
| 1.4 | 测试：冻结后系统服务不崩溃，解冻后恢复正常 | 稳定性测试 |

#### Phase 2: 内核 Dump/Restore ioctl（预计 6-8 周）

目标：实现 BINDER_DUMP_STATE 和 BINDER_RESTORE_STATE

| 步骤 | 任务 | 关键修正 |
|------|------|---------|
| 2.1 | 定义完整的冻结结构 | 补全所有 G1-G5 遗漏的字段 |
| 2.2 | 实现 binder_ioctl_dump_state() | 必须在 freeze 之后调用；遍历 proc 的 nodes/refs/threads rb-tree，序列化到用户空间 buffer |
| 2.3 | 实现 binder_get_ref_for_node_with_desc() | 强制指定 desc 的 ref 创建，需处理 rb-tree 冲突检测 |
| 2.4 | 实现 binder_ioctl_restore_state() | 必须处理：(1) 重建 node with 正确的引用计数标志位，(2) 重建 ref with 正确的 desc + death 状态，(3) 重建线程池参数 |
| 2.5 | 放弃 ServiceManager 内核查找 | 改为：完整恢复 ServiceManager 进程的 binder 状态（它的 nodes 和 refs 一起 dump/restore），不做任何"重新查找" |
| 2.6 | binder_alloc 策略 | 采用 "checkpoint 时 alloc 必须为空" 的前置条件；re-mmap 创建新的 binder_alloc，不尝试恢复内部 buffer 状态 |

#### Phase 3: CRIU 集成（预计 4-6 周）

目标：CRIU 能识别 Binder fd 并调用新 ioctl
| 步骤 | 任务 |
|------|------|
| 3.1 | Binder fd 检测（通过 /proc/pid/fd → readlink → /dev/binder*） |
| 3.2 | 定义 protobuf image format（包含完整冻结结构） |
| 3.3 | Dump path: freeze → dump ioctl → save image |
| 3.4 | Restore path: open binder device → mmap → restore ioctl → unfreeze |
| 3.5 | 关键：实现跨进程协调恢复——按 dependency order 恢复所有共享同一 binder context 的进程 |

#### Phase 4: 端到端验证（预计 2-3 周）

| 步骤 | 验证项 |
|------|--------|
| 4.1 | CRIU C/R 后测试 app 的 isBinderAlive() 返回 true |
| 4.2 | 系统服务调用（ActivityManager, PackageManager）成功 |
| 4.3 | /proc/binder/state before/after 对比一致 |
| 4.4 | 无 DeadObjectException 出现 |
| 4.5 | 压力测试：C/R 期间有并发 IPC 活动时的稳定性 |

### 七、总结

| 维度 | 评价 |
|------|------|
| 问题理解 | ✅ 正确 |
| 方案方向 | ✅ 正确 |
| 可直接实施性 | ❌ 不可以——有 1 个阻塞问题 + 3 个致命错误 |
| 结构完整性 | ⚠️ 部分——核心骨架在，但多个关键字段遗漏 |
| 时间估计 | ❌ 严重低估（实际工作量是声称的 3-5 倍） |
| 修正后可行性 | ✅ 按修正计划执行，理论上可行 |

建议下一步：先聚焦 Phase 0（让 CRIU 能 checkpoint Android 容器），这是所有后续工作的 gate check。