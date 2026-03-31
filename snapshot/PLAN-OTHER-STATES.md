# Android 非 Binder 状态恢复总览

> 本文档是非 Binder 部分的索引和摘要。  
> 完整状态清单在 `PLAN.md`，详细设计在 `PLAN-OTHER-STATES-DETAIL.md`。

## 一、文档树

```text
PLAN-OTHER-STATES.md
└── PLAN-OTHER-STATES-DETAIL.md
```

## 二、问题定义

在“只 checkpoint/restore app 进程”的前提下，CRIU 和 Binder 恢复只能解决一部分问题。

真正困难的是：app 与外部系统共同持有的状态不会自动回滚，包括：

- `system_server` 中的进程、窗口、回调和服务注册
- `SurfaceFlinger` / `InputDispatcher` 中的渲染与输入链路
- 网络、定位、传感器、通知、媒体、输入法等系统服务注册
- GPU、camera、audio 等设备资源

因此非 Binder 恢复的核心不是“保存更多内存”，而是“恢复后如何重新对齐外部世界”。

## 三、总体框架

推荐统一采用 `Quiesce → Dump → Restore → Rebind`：

| 阶段 | 目标 | 关键动作 |
|---|---|---|
| Quiesce | 冻结前收口 | 停动画、flush DB、关闭高风险设备、停止长事务 |
| Dump | 执行 checkpoint | 保存进程和 Binder 基线状态 |
| Restore | 恢复进程本地状态 | 恢复地址空间、线程、fd、Binder |
| Rebind | 对齐外部系统 | 重建窗口、清缓存、重注册回调、重建设备资源 |

## 四、问题树

### 4.1 第一层：进程身份与窗口链路

这是优先级最高的一层：

- `AMS`
- `WMS`
- `SurfaceFlinger`
- 输入链路

原因很简单：如果进程身份、窗口 token、Surface、InputChannel 都不成立，后面的回调型服务也没有稳定落点。

### 4.2 第二层：回调与注册型系统服务

这类服务通常适合走“清缓存 + 重注册 + 幂等对账”：

- AlarmManager / JobScheduler / ContentProvider
- ConnectivityManager / LocationManager / SensorManager
- NotificationManager / MediaSession / AudioFocus / InputMethodManager

### 4.3 第三层：包、权限和策略状态

恢复后的 app 可能已经与当前系统配置不一致，因此还需要做硬门槛校验：

- PackageManager
- runtime permissions
- AppOps
- split APK / shared library / classloader context

## 五、建议的模块树

```text
非 Binder 恢复
├── Orchestrator
│   ├── pre-dump quiesce
│   └── post-restore rebind
├── 身份与窗口
│   ├── AMS
│   ├── WMS
│   └── SurfaceFlinger / Input
├── 回调与注册
│   ├── Alarm / Job / Provider
│   ├── Connectivity / Location / Sensor
│   └── Notification / Media / IME
└── 校验与对账
    ├── Package / Permission / AppOps
    └── 时间 / 网络 / 数据一致性
```

## 六、恢复策略摘要

### 6.1 AMS / WMS：需要显式协商

这部分不能只靠 app 自己重试。

- `AMS` 需要知道该进程处于 checkpoint/frozen/restore 会话中
- `WMS` 需要为窗口、Surface、输入通道提供重连或重建路径
- 这是最可能要求 AOSP framework 修改的区域

### 6.2 回调型服务：优先用幂等重建

这类服务的推荐策略相对统一：

1. 恢复后清掉旧 Binder 缓存
2. 把旧注册视为失效
3. 根据 app 持久化的“期望态”重新注册
4. 对可能重复执行的动作做幂等保护

### 6.3 设备资源：直接按重建设计

对下面这些资源，不应假设它们能透明恢复：

- GPU / EGL / Vulkan
- Camera2
- AudioTrack / AudioRecord
- Sensor 直接通道

更现实的策略是：

- dump 前关闭或静默
- restore 后重新打开和重建

## 七、推荐实现形态

建议拆成三件套：

| 组件 | 位置 | 职责 |
|---|---|---|
| Restore Orchestrator | `system_server` | 编排模块依赖、执行 quiesce/rebind |
| CRIU action script | 容器内脚本 | 串起 checkpoint/restore 钩子 |
| App-side agent | app 进程 | 清缓存、重注册、暴露恢复回调 |

## 八、与顶层计划的关系

| 文档 | 角色 |
|---|---|
| `PLAN.md` | 顶层总计划和完整状态清单 |
| `PLAN-BINDER.md` | Binder 内核态恢复 |
| `PLAN-OTHER-STATES.md` | 非 Binder 总览 |
| `PLAN-OTHER-STATES-DETAIL.md` | 非 Binder 详细方案 |

结论：非 Binder 恢复不是附属问题，而是决定“恢复后的 app 是否真的可用”的主体工程。
