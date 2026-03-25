# Android 非 Binder 状态恢复详细方案

## 一、文档定位

本文档展开 Binder 之外的状态恢复策略，重点回答：

- app 恢复后如何重新对齐 `system_server`
- UI、输入、回调型服务怎样重绑
- 哪些资源必须销毁重建

顶层摘要见 `PLAN-OTHER-STATES.md`，完整状态总表见 `PLAN.md`。

## 二、统一恢复框架

### 2.1 核心原则

CRIU 能恢复进程内存和一部分内核本地状态，但不能自动回滚外部世界。

因此统一采用：

1. `Quiesce`：冻结前收口
2. `Dump`：checkpoint
3. `Restore`：恢复进程和 Binder 基线状态
4. `Rebind`：恢复后主动重绑外部状态

### 2.2 推荐组件

| 组件 | 位置 | 职责 |
|---|---|---|
| Restore Orchestrator | `system_server` | 管理模块顺序与依赖 |
| CRIU action script | 容器内脚本 | 串起 pre-dump / post-restore 钩子 |
| App-side agent | app 进程 | 清缓存、重放注册、暴露恢复回调 |

### 2.3 模块依赖顺序

```text
Binder 恢复
-> AMS 身份恢复
-> WMS / Surface / Input 重建
-> 回调型服务重注册
-> 包/权限/策略校验
-> 解除冻结
```

## 三、AMS：进程身份与生命周期恢复

### 3.1 问题

仅恢复 app 进程时，`AMS` 中以下对象可能已经前进：

- `ProcessRecord`
- `IApplicationThread`
- pid 映射
- service/broadcast/provider 相关记录

如果 AMS 还把该 app 视为旧实例或已死亡实例，恢复后的 Binder 通路即便可用，也会出现：

- 回调投递失败
- service 绑定错乱
- 广播游标推进错误
- provider 引用计数漂移

### 3.2 推荐策略

推荐采用“AMS 显式 checkpoint 会话”：

- checkpoint 前由 AMS 把目标进程标记为 frozen
- 冻结期间 defer 不能安全推进的交互
- restore 后显式通知 AMS 重新关联 thread / pid
- 再统一释放 deferred 操作

### 3.3 第一阶段必须覆盖的点

- `ProcessRecord` 的冻结标记
- pid 与 `IApplicationThread` 重关联
- service/broadcast/provider 的 defer 队列
- 恢复失败时的 kill/restart fallback

## 四、WMS / SurfaceFlinger / 输入链路

### 4.1 问题

恢复后最容易直接损坏的是：

- window token
- `IWindow` client
- `SurfaceControl`
- `BufferQueue`
- `InputChannel`
- HWUI / RenderThread 对 Surface 的绑定

表现通常是：

- 黑屏
- 无输入
- relayout / draw 抛异常
- native 层渲染崩溃

### 4.2 主方案

采用“窗口级重连 + 资源重建”：

- 为窗口引入逻辑身份，如 `restoreId`
- restore 后由 app 请求 WMS 重连该窗口
- WMS 替换 client Binder
- 重新创建 Surface / BufferQueue / InputChannel
- app 侧让 `ViewRootImpl` 与 `ThreadedRenderer` 重新绑定新 Surface

### 4.3 fallback

如果重连失败，则退化为：

- 销毁现有渲染资源
- 触发 Activity/窗口重建

这不够“无缝”，但比盲目沿用旧 Surface 更现实。

## 五、Alarm / Job / Provider

### 5.1 AlarmManager

问题：

- 旧 Binder proxy 失效
- listener / `PendingIntent` 与系统侧状态错位
- checkpoint 期间可能已有闹钟到期

策略：

- 应用持久化闹钟期望态
- restore 后重新获取服务代理
- 对仍有效的闹钟做幂等重放
- 跳过在 checkpoint 时刻之前已经到期的闹钟

### 5.2 JobScheduler

问题：

- service proxy 失效
- 正在运行或待运行的 job 状态与系统侧不一致

策略：

- 恢复后重新获取 `IJobScheduler`
- 以固定 `jobId` 重放期望态
- 借助系统本身“覆盖式 schedule”语义减少冲突

### 5.3 ContentProvider

问题：

- `IContentProvider` 代理失效
- 长连接 client 和引用计数漂移
- cursor / observer 状态不再可信

策略：

- 恢复后清空 provider 缓存
- 关闭旧 client
- 运行期遇到 `DeadObjectException` 时 release -> reacquire -> retry

## 六、Connectivity / Location / Sensor

### 6.1 共性

这三类服务都属于“系统侧注册 + app 侧回调”模型。

恢复后问题通常不是“服务对象找不到”，而是：

- 旧 callback token 已失效
- 系统侧仍保存旧注册
- app 侧以为注册还在，实际回调再也收不到

### 6.2 推荐统一策略

统一做三步：

1. 清本地 Binder/service cache
2. 让系统侧按 `uid/pid` 清除旧注册
3. 按 app 内记录的期望态重新注册

### 6.3 各子系统要点

**ConnectivityManager**

- 可把 restore 视为一次普通“网络状态重新同步”
- 清旧 callback 后重新注册即可

**LocationManager**

- 重建 listener transport
- 重新发起 location request

**SensorManager**

- 丢弃旧 event queue / native channel
- 强制新建 queue 后再注册传感器

## 七、Notification / Media / IME

### 7.1 NotificationManager

问题：

- app 以为通知仍然存在
- 实际通知可能已被用户划掉、系统撤销或重新排序

策略：

- app 持久化“通知期望态”
- restore 后拉取当前活动通知并做对账
- 需要时重发通知
- 若 app 本身是 listener，则请求重绑

### 7.2 MediaSession / AudioFocus

问题：

- session 状态与系统侧显示不同步
- audio focus 栈已变化

策略：

- 重新推送 metadata / playback state
- 若 checkpoint 时持有 audio focus，则 restore 后幂等重申请

### 7.3 InputMethodManager

问题：

- 输入连接、EditorInfo、IME 可见性都会漂移

策略：

- 恢复焦点 view
- 强制 `restartInput`
- 再根据 checkpoint 时的期望态决定 show/hide IME

## 八、Package / Permission / AppOps

### 8.1 为什么必须单独校验

恢复出来的进程内缓存可能已经落后于真实系统状态：

- 包可能更新了
- 组件启用状态可能变了
- 运行时权限可能被撤销
- AppOps 策略可能已调整

### 8.2 推荐策略

restore 后先做一轮硬门槛校验：

- 包名、uid、appId 是否一致
- split / shared library / classloader context 是否仍兼容
- runtime permissions 与 AppOps 是否仍允许关键路径

如果出现不可调和差异，应直接终止恢复并走 restart fallback，而不是让旧堆继续运行。

## 九、时间、网络和数据一致性

### 9.1 时间

恢复后的 `currentTimeMillis` 和 `uptimeMillis` 都可能跳变，影响：

- delayed message
- TTL
- session 过期
- 动画与定时器

建议：

- 对关键超时做 rebase 或限速处理
- 对时间敏感业务重新校验

### 9.2 数据库与本地持久化

SQLite/WAL、SharedPreferences 等在 checkpoint 前需要先收口：

- 结束事务
- checkpoint WAL
- 关闭或 flush 关键连接

否则恢复后容易出现锁 owner 错乱和数据不一致。

## 十、验证矩阵

### 10.1 最低验证项

- app 恢复后不立即崩溃
- AMS/WMS 路径可重新建立
- UI 可见且可输入
- 关键系统服务回调能重新收到
- 通知、网络、定位、传感器至少能重绑一轮

### 10.2 压力验证项

- checkpoint 前后存在并发 IPC
- 存在闹钟、job、provider 访问
- 前后台切换、旋转、焦点变化
- 网络变化、通知重放、传感器持续流

## 十一、完成标准

非 Binder 部分达到以下条件，才算“app 基本可用”：

1. AMS / WMS / 输入链路不再致命损坏
2. 渲染资源可重建
3. 回调型服务能重注册
4. 包/权限/策略状态通过恢复后校验
5. 不可恢复场景有明确 fallback

结论：如果 Binder 恢复解决的是“电话线接通”，那非 Binder 恢复解决的就是“电话那头还是不是同一个系统”。
