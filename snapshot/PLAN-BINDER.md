# Binder 快照/恢复详细方案

## 一、文档定位

本文档只讨论 Binder 内核态的 checkpoint/restore 设计，不展开 CRIU 容器前置问题，也不展开 Binder 之上的系统服务状态恢复。

相关文档：

- `PLAN.md`：顶层总览
- `PLAN-ISSUES-BINDER.md`：当前 Binder draft 的问题与修正
- `PLAN-ISSUES-SOLUTION.md`：CRIU 容器前置阻塞
- `PLAN-OTHER-STATES.md`：非 Binder 状态恢复

## 二、目标与边界

### 2.1 目标

在 app 进程恢复后，重建 Binder 驱动中与该 app 相关的关键状态，使以下对象重新一致：

- `binder_proc`
- `binder_node`
- `binder_ref`
- `binder_thread`
- death notification
- 线程池关键参数

### 2.2 非目标

本文档不负责：

- 解决 mount namespace / cgroup / 容器运行时问题
- 自动修复 AMS/WMS/SurfaceFlinger/设备资源状态
- 在内核里按服务名查询 ServiceManager

## 三、为什么 Binder 不能由 CRIU 直接恢复

CRIU 看到的是：

```text
app fd -> /dev/binder*
```

但 Binder 真正需要恢复的是：

```text
binder_proc
├── nodes
├── refs
├── threads
├── alloc / mmap metadata
└── pending state / death / thread-pool params
```

如果只恢复 fd，不恢复这些内核结构，应用中缓存的 handle 会立即失效。

## 四、设计原则

### 4.1 必须先静默，再 dump

dump/restore 不能在 Binder 正在并发收发事务时进行。必须先拿到稳定点：

- 无在途事务
- `todo` 队列清空
- 无待处理死亡通知
- `binder_alloc` 处于可恢复约束内

### 4.2 恢复单位不是单个 fd，而是整个 Binder context

Binder 的 `node` 和 `ref` 天生跨进程关联：

- server 进程持有 node
- client 进程持有 ref
- handle 编号在各自 `binder_proc` 中有局部意义

因此必须协调恢复同一 Binder context 中的相关进程，不能把某个 app 当成完全独立的 Binder 世界。

### 4.3 恢复顺序必须稳定

建议顺序：

1. 上下文管理者 / 关键服务端进程
2. 服务端 `binder_node`
3. 客户端 `binder_ref`
4. `binder_thread` 与线程池参数
5. death notification
6. 解冻并恢复执行

### 4.4 不在内核中做不存在的语义推断

不应设计以下能力：

- 在内核中按服务名查 ServiceManager 注册表
- 假设当前系统服务状态与 checkpoint 时完全一致
- 依赖当前内核并不存在的 freeze 接口

## 五、需要保存的状态

### 5.1 `binder_proc`

至少要覆盖：

- 所属进程标识
- Binder context
- 线程池参数：`max_threads`、`requested_threads`、`requested_threads_started`
- 死亡/延迟工作相关状态
- mmap 基本信息

### 5.2 `binder_node`

至少要覆盖：

- `ptr`
- `cookie`
- 引用计数与状态位
- 异步事务相关标志
- 影响行为的控制位，例如 `accept_fds`、安全上下文/优先级相关字段

### 5.3 `binder_ref`

至少要覆盖：

- `desc`（handle）
- 指向的目标 node 身份
- strong / weak 引用计数
- death recipient 相关状态

### 5.4 `binder_thread`

至少要覆盖：

- tid
- looper 状态
- 与线程池恢复有关的必要字段

## 六、推荐的 dump/restore 结构

建议按“进程 -> binder fd -> nodes/refs/threads/death/meta”的层级导出。

一个可行的镜像结构可以包含：

- 进程维度标识
- binder 设备路径
- mmap 地址与大小
- node 列表
- ref 列表
- thread 列表
- death 列表
- 线程池和 proc 级参数

关键点不是字段名，而是要保证：

1. 能唯一标识 node/ref 关系
2. 能保留原 handle 编号
3. 能在 restore 时按顺序重建

## 七、静默与稳定点要求

这是 Binder 方案能否落地的第一技术门槛。

### 7.1 dump 前约束

建议将 dump 前置条件明确为：

- 不允许新事务进入
- 已有事务 drain 完成
- `todo` 队列为空
- 无未处理 reply
- `binder_alloc` 不存在难以恢复的残留 buffer 状态

### 7.2 `binder_alloc` 策略

在第一阶段，推荐采用保守策略：

- `binder_mmap()` 仍由正常路径重新建立
- 不尝试恢复复杂的 alloc 内部 buffer 内容
- 将“alloc 必须为空或处于稳定状态”作为 dump 约束

这比试图透明恢复所有内核缓冲更现实。

## 八、恢复顺序

### 8.1 逻辑顺序

```text
restore process memory
-> reopen /dev/binder*
-> remap binder region
-> restore binder_proc metadata
-> restore server-side nodes
-> restore client-side refs with original desc
-> restore thread / thread-pool state
-> restore death notifications
-> unfreeze
```

### 8.2 `desc` 一致性

恢复时必须保留原 handle 编号。否则用户态缓存的 Binder 代理会指向错误对象。

这要求内核提供“按指定 `desc` 建 ref”的恢复路径，而不是沿用普通运行态里的自动分配逻辑。

### 8.3 跨进程协调

对于跨进程 ref，恢复需要满足：

- 目标 node 已存在
- 目标进程已在当前 Binder context 中注册完成
- restore 按统一调度器编排，而不是各进程各自为战

## 九、CRIU 集成点

### 9.1 dump 阶段

CRIU 侧需要做的事：

1. 识别 Binder fd
2. 协调 freeze/quiesce
3. 调用 Binder dump 接口
4. 把结果写入单独镜像

### 9.2 restore 阶段

CRIU 侧需要做的事：

1. 重新打开 binder 设备
2. 恢复到原 fd 编号
3. 重新建立 mmap
4. 按顺序调用 Binder restore 接口
5. 在跨进程层面统一编排恢复顺序

### 9.3 推荐边界

建议把职责切成三层：

- 内核：导出/导入 Binder 结构
- CRIU：镜像格式、流程编排、跨进程协调
- 上层恢复编排器：处理 Binder 之上的系统服务重绑

## 十、分阶段实施建议

### Phase 1：Binder quiesce

目标：

- 建立可验证的稳定点
- 明确 dump 的前置条件

### Phase 2：Binder dump/restore 原型

目标：

- 能导出并恢复基础 `proc/node/ref/thread`
- 能在单一受控场景下保持 handle 一致

### Phase 3：跨进程协调与 CRIU 集成

目标：

- 同一 Binder context 下多进程一起恢复
- 建立真实 end-to-end 路径

### Phase 4：与上层系统服务恢复联调

目标：

- 验证 Binder 恢复后，AMS/WMS/其他服务是否还能完成重绑

## 十一、验收标准

Binder 层至少应验证：

1. 恢复后关键系统服务调用不再立即失败
2. `handle -> target` 对应关系与 checkpoint 前一致
3. 同一 Binder context 中多进程恢复顺序稳定
4. death notification 不丢失或至少有可解释的恢复策略

结论：Binder 恢复的本质是“重建内核态对象图”，而不是“把 `/dev/binder` fd 放回去”。
