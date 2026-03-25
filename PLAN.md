# Android 容器快照/恢复总计划

## 一、文档树

```text
PLAN.md
├── PLAN-BINDER.md
├── PLAN-ISSUES.md
│   ├── PLAN-ISSUES-BINDER.md
│   └── PLAN-ISSUES-SOLUTION.md
└── PLAN-OTHER-STATES.md
    └── PLAN-OTHER-STATES-DETAIL.md
```

建议阅读顺序：

1. `PLAN.md`：总览、路线和完整状态清单
2. `PLAN-ISSUES.md`：当前方案的阻塞项与修正优先级
3. `PLAN-BINDER.md`：Binder 内核态的详细方案
4. `PLAN-OTHER-STATES.md`：非 Binder 状态的恢复框架

## 二、项目背景

当前项目背景是鸿蒙手机终端。在该终端上，安卓应用通过安卓容器兼容运行，但冷启动时间过长，已经成为体验优化的核心问题之一。

因此，本项目不只是单纯研究 Android 容器的 checkpoint/restore 技术可行性，更直接服务于“缩短安卓应用冷启动时间”这一目标。核心思路是评估能否通过容器或应用进程级别的快照/恢复，减少每次重新启动安卓容器、系统服务和应用初始化链路带来的启动开销。

在这个背景下，Binder 句柄失效、系统服务状态漂移、图形与设备状态重建等问题，都是快照恢复方案能否真正用于冷启动优化的关键约束，而不是独立存在的学术问题。

## 三、目标与范围

目标是研究并实现 Android 容器内应用进程的 checkpoint/restore，使恢复后的进程尽量保持原有运行态，而不是简单重启应用。

当前约束如下：

- 场景是同设备、同容器环境下的恢复，不考虑跨设备迁移
- `system_server`、`SurfaceFlinger`、HAL 守护进程默认不参与 checkpoint
- 因此必须同时处理两类问题：
  - `L1`：CRIU 是否能先成功处理 Android 容器本身
  - `L2`：即使 CRIU 成功，Binder 和系统服务状态是否还能一致

## 四、核心结论

### 4.1 Phase 0 是硬前置条件

在当前项目上下文里，第一道 gate 不是 Binder，而是 CRIU 能否成功 checkpoint/restore Android 容器。这个问题的详细分析和备选路线见 `PLAN-ISSUES-SOLUTION.md`。

### 4.2 Binder 恢复是必要条件，但不是充分条件

只恢复 Binder 句柄还不够。App 与 `system_server`、`SurfaceFlinger`、网络对端、HAL 之间联合持有的状态，都会在“只恢复 app 进程”时出现偏移或失效。

### 4.3 推荐采用四阶段恢复模型

统一采用：

1. `Quiesce`：冻结前收口状态
2. `Dump`：执行 CRIU checkpoint，并导出 Binder 关键状态
3. `Restore`：恢复进程、地址空间和 Binder 内核态
4. `Rebind`：对系统服务、窗口、回调、设备和网络状态做重绑/重建

## 五、执行路线摘要

| 阶段 | 目标 | 产出 | 详细文档 |
|---|---|---|---|
| Phase 0 | 让 CRIU 先能处理 Android 容器 | 可成功 C/R 的最小运行环境 | `PLAN-ISSUES-SOLUTION.md` |
| Phase 1 | 设计并实现 Binder 的静默、dump、restore 机制 | Binder 内核态镜像与恢复路径 | `PLAN-BINDER.md`、`PLAN-ISSUES-BINDER.md` |
| Phase 2 | 处理 app 与系统服务的外部联合状态 | AMS/WMS/回调/设备重绑框架 | `PLAN-OTHER-STATES.md` |
| Phase 3 | 做端到端验证与取舍决策 | “可无缝恢复”或“允许部分重建”的结论 | `PLAN-BINDER.md`、`PLAN-OTHER-STATES-DETAIL.md` |

## 六、Binder 方案摘要

Binder 部分只保留顶层要点，详细实现放到 `PLAN-BINDER.md`。

### 6.1 Binder 要恢复的不是 fd，而是整套内核态关系

CRIU 默认只会保留 `/dev/binder*` 这个 fd，本身不会保存：

- `binder_proc`
- `binder_node`
- `binder_ref`
- `binder_thread`
- death notification
- 线程池参数与部分上下文信息

### 6.2 设计原则

- dump/restore 必须建立在 Binder 已静默的前提上
- 不能依赖“在内核里按服务名查 ServiceManager”这种不存在的能力
- 恢复顺序必须是“上下文管理者/服务端节点优先，客户端引用随后”
- 需要跨进程协调恢复整个 Binder context，而不是按单进程孤立恢复

### 6.3 当前建议

- 优先补齐 Binder quiesce/freeze 机制
- 把 Binder 详细方案与问题修正拆开看：
  - `PLAN-BINDER.md` 讲目标方案
  - `PLAN-ISSUES-BINDER.md` 讲当前 draft 的错误和必须修正项

## 七、非 Binder 状态摘要

除 Binder 外，真正困难的是 app 与外部系统的联合状态。顶层只保留三个判断：

1. `AMS/WMS` 是最高优先级，因为它们决定进程身份、窗口、输入和生命周期是否还成立
2. `SurfaceFlinger/HWUI/GPU` 相关状态基本都要按“重建资源”思路处理，不能指望 CRIU 透明恢复
3. 其余回调型服务（定位、网络、传感器、通知、媒体、输入法等）更适合按“清缓存 + 重注册 + 幂等对账”处理

详细设计见 `PLAN-OTHER-STATES.md` 和 `PLAN-OTHER-STATES-DETAIL.md`。

## 八、应用快照需要恢复的完整状态清单

核心结论：CRIU 能恢复大部分进程内 + 内核本地状态（线程、堆内存、多数 FD），但凡是与外部进程联合持有的状态（Android 系统服务、HAL 守护进程、SurfaceFlinger、网络对端）在仅恢复 app 进程时都会失效或不一致。

### 8.1 当前项目覆盖范围

顶层方案专注于两件事：

- `PLAN-BINDER.md`：Binder 内核态（`binder_proc` / `binder_node` / `binder_ref` / `binder_thread`）
- `PLAN-OTHER-STATES.md`：Binder 恢复之后，app 与系统服务的外部一致性恢复

### 8.2 完整状态清单（7 大类）

图例：P0 = 应用崩溃，P1 = 功能失效，P2 = 细微问题；CRIU = Full/Partial/No

#### 1. 内核级状态（非 Binder）

| 状态 | 失效表现 | 严重度 | CRIU | 需要的额外工作 |
|---|---|:---:|:---:|---|
| 常规文件 FD | 通常 OK；文件被修改时内容不一致 | P2 | Full | 确保挂载/路径稳定 |
| ashmem FD | 共享内存区域丢失/归零，native 崩溃 | P0 | No | 需自定义 dump/restore ashmem 内容 |
| memfd | ASharedMemory 共享失败 | P0/P1 | Partial | 验证 CRIU memfd 支持 |
| Unix 域 socket（已连接） | 对端未 checkpoint → 连接断开（logd/netd/statsd） | P0/P1 | Partial | 恢复后重连 |
| TCP/UDP socket | NAT 超时/对端 RST | P1 | Partial | 重连 + 幂等重试 |
| eventfd / timerfd / epoll | 事件循环卡死或定时器立即触发 | P0/P1 | Full | 配合时间策略调整 |
| inotify / signalfd | 丢失事件 / 信号语义漂移 | P1 | Partial | 恢复后重建 watcher |
| 设备 FD（GPU/camera/audio/ion/drm） | 驱动拒绝、IO 错误、native 崩溃 | P0 | No | dump 前关闭，恢复后重新打开 |
| dmabuf / GraphicBuffer | 渲染管线爆炸，黑屏或 SIGSEGV | P0 | No | 释放 buffer → 重建 Surface/EGL |
| 匿名映射（堆/栈/JIT） | 通常 OK | — | Full | — |
| 文件映射（DEX/OAT/.so） | 文件被修改时崩溃 | P0 | Full | 确保 base image 不变 |
| 信号处理器/掩码 | 通常 OK | P0 | Full | — |
| futex / 条件变量 | 恢复到稳定点即可 | P1 | Full | 在 quiesce 点冻结 |
| PID 命名空间 | PID 变化 → AMS/WMS 的 `ProcessRecord` 预期被打破 | P0/P1 | Partial | 必须保持 PID 一致或与 AMS 协商 |
| SELinux 上下文 | Binder/设备访问检查失败 | P0 | Partial | 恢复到相同上下文 |

#### 2. Android 系统服务状态（app ↔ system_server 联合持有）

这是最复杂的一层。系统服务通过 Binder token、PID/UID、window token、death recipient 来跟踪每个 app。仅恢复 app 进程不会回滚这些注册。

| 服务 | 持有的 app 状态 | 失效后果 | 严重度 | 恢复方式 |
|---|---|---|:---:|---|
| AMS (`ProcessRecord` + `IApplicationThread`) | 进程生命周期、adj、bound service、FGS、broadcast receiver 注册 | AMS 认为进程已死；回调失效；ANR | P0 | 重新 attach 或 force-stop + 重启 Activity（但丢失内存状态） |
| WMS (窗口 token + `SurfaceControl` + input channel) | Surface 层级、输入通道、焦点、可见性 | UI 黑屏/冻结；触摸/按键无响应 | P0/P1 | 重建窗口/Surface；触发 Activity recreate |
| SurfaceFlinger | `BufferQueue`、图层状态、sync fence | 渲染管线崩溃 | P0 | 重建 Surface + EGL 上下文 |
| InputMethodManager | 输入连接、IME session、光标状态 | 键盘不弹出或输入无响应 | P1 | 重建 `ViewRoot` / 重启输入 |
| AlarmManager | 已调度闹钟（RTC/ELAPSED）、`PendingIntent` | 闹钟在冻结期间触发；app 认为未触发 | P1 | 恢复后对账 + 重新调度 |
| JobScheduler | 任务队列、约束、退避、执行历史 | 任务重复执行或丢失 | P1 | 重新绑定回调；幂等键 |
| ContentProvider 连接 | stable/unstable ref、cursor window、URI 权限 | cursor 无效；observer 死亡 | P1 | quiesce 时关闭 cursor/txn；恢复后重新查询 |
| NotificationManager | 已发通知、channel、listener 绑定 | 回调断开；`PendingIntent` 指向旧进程 | P1/P2 | 重新注册 listener；按需重发 |
| ConnectivityManager / `NetworkCallback` | 网络请求、回调、socket tagging | 回调停止；socket 可能在已死网络上 | P1 | 重新注册回调；视为网络变化事件 |
| LocationManager | 活跃请求、listener/`PendingIntent` | 不再收到更新 | P1 | 重新请求定位更新 |
| SensorManager | 已启用传感器、采样率、直接通道 | 无事件；直接通道 buffer 无效 | P1 | 反注册 + 重注册 |
| MediaSession / AudioFocus | 播放状态、回调、音频焦点 | 焦点状态不匹配；回调断开 | P1 | 重建 session + 重新获取焦点 |

#### 3. 框架 / 运行时状态

| 状态 | 失效表现 | 严重度 | CRIU | 额外工作 |
|---|---|:---:|:---:|---|
| Handler/Looper 消息队列 | delayed 消息在恢复后立即/延迟触发 | P1/P2 | Full（内存） | 可选：rebase 延迟消息时间基准 |
| 线程池 / Executor | 任务恢复执行但可能引用已失效的外部句柄 | P1 | Full | 在恢复后用 `ready latch` 把关 |
| Choreographer | vsync 源通过 SurfaceFlinger → 断开 | P1 | No（依赖 SF） | 重建渲染管线 |
| View 系统 / HWUI 渲染线程 | EGL/Surface 无效 → native crash | P0/P1 | No | 销毁 + 重建 Surface/EGL/GL 资源 |
| SharedPreferences | `apply()` 异步写；冻结时可能 mid-flight | P2 | Full | quiesce 时 `commit()` |
| SQLite 连接 + WAL | 冻结时若在事务中 → 锁 owner 不匹配、数据损坏 | P0/P1 | Partial | quiesce 时结束事务 + checkpoint WAL + 关闭 DB |
| ContentObserver 注册 | 不再收到变化通知 | P1 | No | 重注册 observer |

#### 4. 非 Binder IPC

| 机制 | 失效表现 | 严重度 | CRIU | 额外工作 |
|---|---|:---:|:---:|---|
| Unix socket → logd | 日志阻塞 | P1 | Partial | 恢复后重连 logger socket |
| Unix socket → netd/resolv | DNS/网络操作失败 | P1 | Partial | 强制网络栈重初始化 |
| ashmem/memfd 共享内存 | 生产者/消费者不一致 | P0/P1 | Partial/No | 重建共享区域 + 重发句柄 |
| Pipe (`ParcelFileDescriptor`) | 对端不在 checkpoint 中 → broken pipe | P1 | Partial | 关闭 PFD；恢复后重新协商 |

#### 5. 硬件 / 设备状态（几乎全部需要重新初始化）

| 子系统 | 失效表现 | 严重度 | CRIU | 额外工作 |
|---|---|:---:|:---:|---|
| Camera2 session | session 无效，buffer 被拒 | P0/P1 | No | dump 前关闭相机；恢复后重建 session |
| AudioTrack / AudioRecord | 死轨，underrun，焦点不匹配 | P1/P0 | No | 重建 track/record + 重同步时间戳 |
| GPU/EGL/Vulkan 上下文 | context lost，驱动拒绝 | P0 | No | 全部重建上下文 + 重载纹理/shader |
| Sensor HAL 直接通道 | 无效 channel ID/buffer | P1 | No | 重建通道 + 重启传感器 |

#### 6. 网络状态

| 状态 | 失效表现 | 严重度 | CRIU | 额外工作 |
|---|---|:---:|:---:|---|
| TCP 已建立连接 | 对端超时/RST；NAT 表项过期 | P1 | Partial | 重连 + 幂等重试 |
| DNS 缓存 | 过期 | P2 | Yes | 重解析 |
| HTTP/2 连接池 | stream reset，TLS session 无效 | P1 | No | 重建 client/pool |
| WebSocket | 服务端断开 | P1 | Partial | 重连 + 重订阅 |

#### 7. 时间敏感状态

| 状态 | 失效表现 | 严重度 | CRIU | 额外工作 |
|---|---|:---:|:---:|---|
| 墙钟跳变 (`currentTimeMillis`) | 认证/session 过期、缓存 TTL 错误 | P1/P2 | N/A | 重新验证时间相关假设 |
| 单调时钟漂移 (`uptimeMillis`) | delayed 任务立刻“追赶”执行 | P1 | N/A | 限速或 rebase 超时 |
| `Handler.postDelayed` | 恢复后突发执行 | P1/P2 | Full（队列） | 重算 deadline |
| 动画（`ValueAnimator`） | 跳帧/闪烁 | P2 | N/A | 取消 + 重启动画 |

### 8.3 推荐的恢复架构

根据分析，建议采用 `quiesce → dump → restore → rebind` 四阶段设计：

1. `Quiesce`：停止动画、flush SharedPreferences/DB、关闭 camera/audio/sensor、drain 外部 socket、结束 Binder 事务
2. `Dump`：冻结进程，dump 全部内核态 + 进程内存 + Binder 状态
3. `Restore`：恢复进程、内存映射、Binder 内核态
4. `Rebind`：检测断开的 Binder/socket/native 句柄；重连 logd/netd；重注册回调；重建 Surface/EGL；调整时间基准

对于前台 UI app 的无缝恢复，需要要么：

- checkpoint 整个 Android userspace（`system_server` + `SurfaceFlinger` + HAL + app）
- 接受恢复后 Activity/窗口/渲染资源的部分重建

### 8.4 当前计划的 Gap 归纳

| 维度 | 当前覆盖 | 缺口 |
|---|---|---|
| Binder 内核态 | `PLAN-BINDER.md` | 需要进一步实现 quiesce、跨进程恢复与 CRIU 集成 |
| ashmem/memfd | ❌ | 需要单独设计 |
| 系统服务状态 | `PLAN-OTHER-STATES.md` | 需要逐模块落地 |
| 设备 FD（GPU/camera/audio） | ⚠️ 仅有原则 | 需要 quiesce hook + post-restore 重建 |
| 网络连接 | ⚠️ 仅有原则 | 需要统一重连策略 |
| 时间处理 | ⚠️ 仅有原则 | 需要 rebase/限速策略 |
| SQLite/WAL | ⚠️ 仅有原则 | 需要 checkpoint 前的一致性收口 |

结论：Binder 是最底层、最关键的一步，但真正决定“恢复后 app 能不能继续工作”的，是 Binder 之上的系统服务和设备状态恢复。
