# Android 系统服务状态恢复方案

> 本文档是 `PLAN.md`（Binder C/R 方案）的扩展，详细说明除 Binder 外，Android 应用进程级快照恢复需要处理的系统服务状态问题及解决方案。

**适用场景**：
- Android 12 容器（ReDroid/LXC）
- 仅对 App 进程进行 CRIU checkpoint/restore
- system_server **不**参与 checkpoint
- Binder 内核态状态由 `PLAN.md` 中的内核插件恢复

---

## 目录

1. [总览：Quiesce/Rebind 框架架构](#1-总览quiescerebind-框架架构)
2. [ActivityManagerService (AMS) 状态恢复](#2-activitymanagerservice-ams-状态恢复)
3. [WindowManagerService (WMS) / SurfaceFlinger 状态恢复](#3-windowmanagerservice-wms--surfaceflinger-状态恢复)
4. [AlarmManager / JobScheduler / ContentProvider 状态恢复](#4-alarmmanager--jobscheduler--contentprovider-状态恢复)
5. [ConnectivityManager / LocationManager / SensorManager 状态恢复](#5-connectivitymanager--locationmanager--sensormanager-状态恢复)
6. [NotificationManager / MediaSession / InputMethodManager 状态恢复](#6-notificationmanager--mediasession--inputmethodmanager-状态恢复)
7. [PackageManager / 权限 / AppOps 状态校验](#7-packagemanager--权限--appops-状态校验)
8. [验证与测试矩阵](#8-验证与测试矩阵)
9. [与 Flux 论文方案的对比分析](#9-与-flux-论文方案的对比分析)

---

## 1. 总览：Quiesce/Rebind 框架架构

### 1.1 核心原则

**CRIU 能恢复进程内 + 内核本地状态，但凡是与外部进程联合持有的状态（系统服务、HAL、SurfaceFlinger、网络对端）都会失效或不一致。**

因此采用 **Quiesce → Dump → Restore → Rebind** 四阶段设计：

| 阶段 | 目标 | 关键动作 |
|------|------|----------|
| **Quiesce** | 冻结前收口状态 | 停止动画、flush DB、关闭 camera/audio/sensor、结束 Binder 事务、通知 AMS 进入冻结态 |
| **Dump** | CRIU checkpoint | 冻结进程，dump 全部内核态 + 进程内存 + Binder 状态 |
| **Restore** | CRIU restore | 恢复进程、内存映射、Binder 内核态 |
| **Rebind** | 恢复后重绑 | 检测断开的连接，重注册回调，重建 Surface/EGL，调整时间基准 |

### 1.2 服务恢复依赖图

```
Binder 恢复 (内核插件)
    ↓
AMS reattach (进程身份/调度)
    ↓
WMS rebuild (窗口/Surface/输入)
    ↓
┌───────────────┬───────────────┬───────────────┐
↓               ↓               ↓               ↓
PMS/Permission  ContentProvider  Alarm/Job    Notification
校验            连接恢复         重调度        /Media/IME
```

### 1.3 框架实现架构（三件套）

| 组件 | 位置 | 职责 |
|------|------|------|
| **RestoreOrchestratorService** | system_server 内常驻服务 | 持有模块 registry，编排依赖顺序，执行 quiesce/rebind 流程 |
| **CRIU Action Script** | 容器内 root 权限脚本 | 在 pre-dump/post-restore 阶段调用编排器，处理冻结/解冻 |
| **App-side Agent** | 应用内可选库 | 提供 quiesce()/postRestoreRebind() 回调与清缓存能力 |

### 1.4 编排器伪代码

```java
interface RestoreModule {
    String name();
    List<String> dependsOn();
    Result preDump(Session s);
    Result postRestore(Session s);
    boolean required();
}

class RestoreOrchestratorService {
    Map<String, RestoreModule> modules;
    DAG order = topoSort(modules);

    Result beginQuiesce(int pid, int uid, String pkg, int userId) {
        Session s = new Session(pid, uid, pkg, userId, sessionId=genId());
        s.pkgSnapshot = capturePkgSnapshot(pkg, userId);

        if (!AppAgent.quiesce(pid, timeoutMs=2000)) return FAIL;

        for (RestoreModule m : order) {
            Result r = m.preDump(s);
            if (r.fail && m.required) return FAIL;
        }
        return OK_WITH_SESSION(s);
    }

    Result postRestore(long sessionId, int restoredPid) {
        Session s = loadSession(sessionId);
        s.pid = restoredPid;
        freezeProcess(restoredPid);

        // 先做不可和解检查
        ReconcileResult rr = reconcilePkgState(s.pkgSnapshot);
        if (rr == UNRECOVERABLE) {
            kill(restoredPid);
            return FAIL_RESTART;
        }

        for (RestoreModule m : order) {
            Result r = m.postRestore(s);
            if (r.fail && m.required) {
                kill(restoredPid);
                return FAIL_RESTART;
            }
        }

        AppAgent.notify(restoredPid, "RESUME");
        unfreezeProcess(restoredPid);
        return OK;
    }
}
```

### 1.5 与 PLAN.md Binder C/R 的集成顺序

```
1. CRIU restore（进程恢复）
2. Binder 内核插件恢复 binder driver 状态（handle/node/ref 一致）
3. system_server 编排器开始 postRestore(session)
4. AMS reattach → WMS rebuild → PMS/Permission reconcile → 其他模块
5. 解除冻结，app resume
```

---

## 2. ActivityManagerService (AMS) 状态恢复

### 2.1 问题分析：哪些状态会不一致

> **根因**：App 进程被回滚到旧堆/旧线程状态，而 system_server（AMS）持续前进。AMS 中所有指向该进程的"活体引用"都可能冲突。

| AMS 数据结构 | 失效原因 | 后果 |
|-------------|---------|------|
| `ProcessRecord.mThread` (IApplicationThread) | AMS 可能已置空/替换/death link 断开 | scheduleReceiver/scheduleCreateService 失败 |
| `mPidsSelfLocked` (pid→ProcessRecord 映射) | pid 变化或 AMS 已清理映射 | 找不到进程或指向错误实例 |
| `ProcessRecord.mStartSeq` | CRIU 不走 zygote 启动路径 | AMS 的 ABA 防护可能拒绝旧世代 |
| `ServiceRecord.app` / `ConnectionRecord` | 冻结期的 bind/unbind 无法回放 | 连接计数与时序不一致 |
| `BroadcastRecord.nextReceiver` | 冻结期游标继续推进 | 漏投/重复投/超时判死 |
| `ContentProviderConnection` | 引用计数漂移 | 连接泄漏或提前释放 |

### 2.2 解决方案选项

| 方案 | 描述 | 优点 | 缺点 | 工作量 |
|------|------|------|------|--------|
| **C. AMS Hook + 冻结协议** (推荐) | 新增 `prepareCriuCheckpoint`/`notifyCriuRestored` AIDL，冻结期 defer 所有不可回放交互 | 不需 checkpoint system_server，可控可扩展 | 需改 AOSP framework | Medium |
| A. Reattach | 复用 `attachApplication` 刷新 thread/pid | 改动小 | 无法处理冻结期已推进的状态 | Short-Medium |
| B. Controlled Restart | force-stop + relaunch 保留 heap | AMS 侧最干净 | 与保留 heap 目标冲突大 | Large |
| D. Full Cohort Checkpoint | system_server 一起 checkpoint | 语义最完整 | 工程复杂度极高 | Large |

### 2.3 推荐方案：AMS Hook + 冻结协议

#### 2.3.1 AIDL 接口设计

```aidl
// IActivityManager.aidl
void prepareCriuCheckpoint(String packageName, int userId, long checkpointId, int flags);
void notifyCriuRestored(String packageName, int userId, long checkpointId,
                        in IApplicationThread thread, int restoredPid, int flags);
```

#### 2.3.2 ProcessRecord 新增字段

```java
// ProcessRecord.java
boolean mCriuFrozen;
long mCriuCheckpointId;
long mCriuFreezeUptime;

boolean isCriuFrozen() { return mCriuFrozen; }
void setCriuFrozen(long checkpointId, boolean frozen, long nowUptime) {
    mCriuFrozen = frozen;
    mCriuCheckpointId = checkpointId;
    mCriuFreezeUptime = nowUptime;
}
```

#### 2.3.3 AMS：prepareCriuCheckpoint()

```java
// ActivityManagerService.java
public void prepareCriuCheckpoint(String pkg, int userId, long checkpointId, int flags) {
    synchronized (this) {
        ProcessRecord app = findAppProcessLocked(pkg, userId);
        if (app == null) throw new IllegalStateException("No process");

        app.setCriuFrozen(checkpointId, true, SystemClock.uptimeMillis());

        // 冻结期保护：避免被 LMK 杀
        updateOomAdjLocked(app, OomAdjuster.OOM_ADJ_REASON_NONE);

        mCriuSessions.put(checkpointId, new CriuSession(app, ...));
    }
}
```

#### 2.3.4 冻结期 Defer 规则

**Broadcast（BroadcastQueue）**：
```java
if (targetApp != null && targetApp.isCriuFrozen()) {
    // 不推进 nextReceiver，不 finish，不触发超时
    deferBroadcastLocked(r, "criu_frozen");
    return;
}
```

**Service（ActiveServices）**：
```java
if (app != null && app.isCriuFrozen()) {
    enqueueCriuPendingServiceOp(sr, OP_START_OR_BIND);
    return; // 不调用 scheduleCreateService/scheduleBindService
}
```

**ContentProvider（ContentProviderHelper）**：
```java
if (providerProc != null && providerProc.isCriuFrozen()) {
    deferProviderOpLocked(...);
    return null;
}
```

#### 2.3.5 AMS：notifyCriuRestored()

```java
public void notifyCriuRestored(String pkg, int userId, long checkpointId,
                               IApplicationThread thread, int restoredPid, int flags) {
    synchronized (this) {
        ProcessRecord app = findAppProcessLocked(pkg, userId);
        enforceCallingUidMatches(app);

        if (app == null || !app.isCriuFrozen() || app.mCriuCheckpointId != checkpointId) {
            throw new IllegalStateException("No matching frozen session");
        }

        // 1) 刷新 pid 映射
        mProcessList.removePidLocked(app);
        app.setPid(Binder.getCallingPid());
        mProcessList.addPidLocked(app);

        // 2) 刷新 thread + death recipient
        app.makeActive(thread, mProcessStats);

        // 3) 解除冻结
        app.setCriuFrozen(checkpointId, false, SystemClock.uptimeMillis());

        // 4) 重算调度
        updateOomAdjLocked(app, OomAdjuster.OOM_ADJ_REASON_NONE);

        // 5) 恢复 deferred 操作
        mServices.onCriuThawLocked(app);
        mBroadcastQueues.onCriuThawLocked(app);
        mCpHelper.onCriuThawLocked(app);

        reconcileInvariantsLocked(app);
    }
}
```

#### 2.3.6 边界场景处理

| 场景 | 冻结期策略 | Thaw 后处理 |
|------|-----------|------------|
| 前台/后台切换 | 第一阶段不支持，或 defer 此类事件 | 交由 ATMS/WM 重同步 |
| bound services | 新 bind/unbind 入队不投递 | 按原顺序调用 requestServiceBindingLocked |
| started services | startService args 入 pendingStarts | 先补齐 scheduleCreateService，再投递 args |
| FGS | 禁止推进 FGS 状态机 | 先恢复 service，再恢复 FGS 通知状态 |
| pending broadcasts | 不推进 nextReceiver，不触发超时 | 从同一 receiver 继续投递 |
| ContentProvider | acquire/release 延后 | 重试 deferred 操作 |

#### 2.3.7 AOSP 代码路径（Android 12）

- `frameworks/base/core/java/android/app/IActivityManager.aidl`
- `frameworks/base/services/core/java/com/android/server/am/ActivityManagerService.java`
- `frameworks/base/services/core/java/com/android/server/am/ProcessRecord.java`
- `frameworks/base/services/core/java/com/android/server/am/BroadcastQueue.java`
- `frameworks/base/services/core/java/com/android/server/am/ActiveServices.java`
- `frameworks/base/services/core/java/com/android/server/am/ContentProviderHelper.java`

---

## 3. WindowManagerService (WMS) / SurfaceFlinger 状态恢复

### 3.1 问题分析：CRIU 恢复后为何 UI/输入会碎

| 状态 | 失效原因 | 后果 |
|------|---------|------|
| **Window token / IWindow** | 客户端恢复后 binder proxy handle 失效；system_server 持有的 app 端 binder 引用也可能失效 | WMS 认为窗口 client 死亡并清理 |
| **SurfaceControl / SurfaceComposer** | `SurfaceControl` 握着指向 SurfaceFlinger layer 的 binder handle | Transaction/BLAST 提交失败 |
| **BufferQueue** | `android.view.Surface` 依赖 `IGraphicBufferProducer` | producer/consumer 绑定链断裂，dequeue/queueBuffer 失败或黑屏 |
| **InputChannel** | FD 恢复后，InputDispatcher 侧连接仍依赖窗口 token/注册表 | 输入窗口表不一致，事件不投递 |
| **硬件渲染管线（HWUI）** | RenderThread 的 EGLContext/Vk 资源与 BufferQueue 强绑定 | GPU/driver 状态不保证可继续用 |

### 3.2 解决方案选项

| 方案 | 描述 | 优点 | 缺点 | 工作量 |
|------|------|------|------|--------|
| **窗口级重连 + 资源重建** (推荐) | 用 `restoreId` 找回 WindowState，替换 binder client，重建 SurfaceControl/BufferQueue/InputChannel | App 不重启，保留进程状态 | 需改 AOSP framework + WMS | Large |
| A. 直接重启 Activity | 检测恢复后 kill+relaunch | UI/输入自然重建 | 丢失进程内瞬时状态 | Small |
| B. 内核/驱动级 CRIU | Binder/GPU/Input 原生可 checkpoint | 语义完整 | 工作量巨大，不稳定 | Very Large |
| C. `[Flux借鉴]` 销毁渲染资源 + 自然重建 | 仅销毁硬件渲染资源（destroyHardwareResources），保留窗口/Activity，由下一次 performTraversals 自然重建 Surface + EGL | 不重启 Activity，工程复杂度远低于方案推荐 | 丢失窗口位置/z-order 等精细状态；重建过程可能有短暂黑屏 | Medium |

> **推荐策略**：以「窗口级重连 + 资源重建」为主方案，以「`[Flux借鉴]` 销毁-重建」为 fallback。当 reconnectWindow 失败（如 restoreId 找不到匹配 WindowState）时自动降级到销毁-重建路径。

### 3.3 推荐方案：窗口级重连 + 资源重建

#### 3.3.1 restoreId：用逻辑身份绕开失效 binder token

- **WMS 侧**：在 `WindowState` 增加 `mRestoreId`（随机 128-bit），维护 `Map<restoreId, WindowState>`
- **客户端**：`ViewRootImpl` 保存 `restoreId`，用于后续重连

#### 3.3.2 重连入口：IWindowSession.reconnectWindow(...)

```aidl
// IWindowSession.aidl
void reconnectWindow(
    long restoreId,
    in IWindow client,
    int seq,
    out SurfaceControl outSurfaceControl,
    out InputChannel outInputChannel,
    out InsetsState outInsetsState,
    out Rect outFrame
);
```

**服务端行为**：
1. 校验 callingUid 与 WindowState 记录 uid 一致
2. 替换 `WindowState.mClient = newClient`
3. 重建 SurfaceControl/Layer/BufferQueue
4. 重建 InputChannel 并注册到 InputDispatcher
5. 返回新的 `SurfaceControl` / `InputChannel` 给 app

#### 3.3.3 WMS 侧实现

```java
// WindowManagerService / Session
void reconnectWindow(long restoreId, IWindow newClient, int seq, Out out) {
  synchronized (mGlobalLock) {
    WindowState w = mRestoreIdToWindow.get(restoreId);
    if (w == null) throw new IllegalArgumentException("unknown restoreId");

    enforceCallingUidMatches(w);
    w.mClient = newClient;

    // 1) 输入：重建通道并注册
    InputChannel[] channels = InputChannel.openInputChannelPair(w.makeInputName());
    mInputManager.registerInputChannel(channels[0], w.getDisplayId());
    w.setInputChannel(channels[0]);
    out.outInputChannel = channels[1];

    // 2) 渲染：销毁并重建 SurfaceControl
    w.destroySurfaceLocked();
    w.createSurfaceLocked();
    out.outSurfaceControl = w.getSurfaceControlForClient();

    // 3) 推送新的 InputWindows
    mInputMonitor.updateInputWindowsLw(/*force*/ true);
  }
}
```

#### 3.3.4 App 侧：ViewRootImpl 捕获失败并重连

```java
// ViewRootImpl
void performTraversals() {
  try {
    relayoutWindowNormally();
    drawNormally();
  } catch (DeadObjectException | TransactionTooLargeException e) {
    if (tryReconnectWindow()) {
      // 让 HWUI 把旧 surface 当作丢失，重建 GPU 管线
      threadedRenderer.setSurface(null);
      threadedRenderer.setSurface(mSurface);
      invalidate();
    } else {
      scheduleCrashOrRelaunch();
    }
  }
}

boolean tryReconnectWindow() {
  IWindowSession s = WindowManagerGlobal.getWindowSession();
  ReconnectResult r = s.reconnectWindow(mRestoreId, mWindow, mSeq, ...);
  mSurfaceControl = r.surfaceControl;
  mInputChannel = r.inputChannel;
  mSurface = new Surface();
  mSurface.copyFrom(mSurfaceControl);
  return true;
}
```

#### 3.3.5 边界场景处理

| 场景 | 处理方式 |
|------|---------|
| SurfaceView/TextureView | 各自独立 SurfaceControl，需要同样走 reconnect |
| 安全性 | restoreId 不可预测且与 uid 绑定 |
| 资源泄漏 | 重建前确保旧 InputChannel/unregister、旧 SurfaceControl release |

#### 3.3.6 AOSP 代码路径（Android 12）

- `frameworks/base/services/core/java/com/android/server/wm/WindowManagerService.java`
- `frameworks/base/services/core/java/com/android/server/wm/WindowState.java`
- `frameworks/base/services/core/java/com/android/server/wm/WindowSurfaceController.java`
- `frameworks/base/services/core/java/com/android/server/wm/InputMonitor.java`
- `frameworks/base/core/java/android/view/ViewRootImpl.java`
- `frameworks/base/core/java/android/view/ThreadedRenderer.java`
- `frameworks/native/services/surfaceflinger/SurfaceFlinger.cpp`
- `frameworks/native/services/inputflinger/dispatcher/InputDispatcher.cpp`

#### 3.3.7 工作量估计

**Large（3 天+）**
---

## 4. AlarmManager / JobScheduler / ContentProvider 状态恢复

### 4.1 问题分析

#### 4.1.1 AlarmManager

| 状态 | 失效表现 |
|------|---------|
| `IAlarmManager` 缓存 | 旧 handle，调用直接 `DeadObjectException` |
| `OnAlarmListener` 闹钟 | listener binder 绑定在 system_server，恢复后旧 handle 失效，形成幽灵闹钟 |
| `PendingIntent` 闹钟 | 旧 wrapper token 无效，cancel/update 失败 |

#### 4.1.2 JobScheduler

| 状态 | 失效表现 |
|------|---------|
| `IJobScheduler` 缓存 | `schedule()`/`cancel()` 失败 |
| 正在运行的 JobService | 回调链路断裂，执行中断，触发重试/失败策略 |

#### 4.1.3 ContentProvider

| 状态 | 失效表现 |
|------|---------|
| `IContentProvider` 代理 | 首次 query/insert/update 即 `DeadObjectException` |
| `ContentProviderClient` 长连接 | 引用计数/unstable 引用不一致 |

### 4.2 解决方案

**核心原则**：把 CRIU 恢复等价为"一次进程重连/软重启"——清空缓存，幂等重放。

#### 4.2.1 恢复钩子：进程内统一断开并重建缓存

```java
// ActivityThread.java
void handleCriuRestore() {
    // 1) 清空系统服务缓存
    ServiceManager.clearCache();
    ActivityManager.invalidateSingleton();

    // 2) 清空 Context 的 system service cache
    ContextImpl base = (ContextImpl) mInitialApplication.getBaseContext();
    base.clearServiceCache();

    // 3) Provider：关掉所有 client + 清空 provider map
    for (ProviderClientRecord r : mProviderMap.values()) {
        closeQuietly(r.mClient);
    }
    mProviderMap.clear();

    // 4) 通知应用层做对账/再注册
    if (mInitialApplication instanceof CriuRestorable) {
        ((CriuRestorable) mInitialApplication).onCriuRestored();
    }
}
```

#### 4.2.2 Alarm reconciliation（闹钟重对账）

**策略**：应用持久化闹钟期望态，恢复后执行幂等重放。`[Flux借鉴]` 增加 checkpoint-time 过滤——跳过在 checkpoint 时刻之前已到期的闹钟，避免无意义的重调度。

```java
// AlarmManager.java：DeadObject 重连
private IAlarmManager getServiceFresh() {
    return IAlarmManager.Stub.asInterface(
        ServiceManager.getService(Context.ALARM_SERVICE));
}

private <T> T callWithRetry(Callable<T> c) throws RemoteException {
    try {
        return c.call();
    } catch (DeadObjectException e) {
        mService = getServiceFresh();
        return c.call(); // retry once
    }
}

// 应用侧闹钟重放
void onCriuRestored(long checkpointUptimeMs) {
    long checkpointWallTimeMs = convertUptimeToWallTime(checkpointUptimeMs);
    List<AlarmSpec> specs = loadFromDisk();
    for (AlarmSpec s : specs) {
        // [Flux借鉴] 跳过在 checkpoint 之前已到期的闹钟
        if (s.triggerAtMillis <= checkpointWallTimeMs) {
            Log.d(TAG, "Skipping expired alarm: " + s.requestCode);
            continue;
        }
        PendingIntent pi = PendingIntent.getBroadcast(
            ctx, s.requestCode, s.intent, FLAG_UPDATE_CURRENT | FLAG_IMMUTABLE);
        alarmManager.setExactAndAllowWhileIdle(s.type, s.triggerAtMillis, pi);
    }
}
```

#### 4.2.3 Job re-registration（Job 重新注册）

**策略**：恢复后对应存在的 jobs 做 schedule 重放，依赖 jobId+uid 覆盖语义。

```java
// JobSchedulerImpl.java：DeadObject 重连
int schedule(JobInfo job) {
  try {
    return mBinder.schedule(job);
  } catch (DeadObjectException e) {
    mBinder = IJobScheduler.Stub.asInterface(
        ServiceManager.getService(Context.JOB_SCHEDULER_SERVICE));
    return mBinder.schedule(job);
  }
}

// 应用侧 job 重放
void onCriuRestored() {
  for (JobSpec s : loadJobsFromDisk()) {
    JobInfo ji = buildJobInfo(s); // jobId 固定
    jobScheduler.schedule(ji);    // 覆盖式再注册
  }
}
```

#### 4.2.4 Provider connections（Provider 连接重建）

**策略**：恢复后把所有 provider 代理视为已死亡，清缓存；运行期遇到 `DeadObjectException` 做 release→reacquire→retry。

```java
// ContentResolver 统一重试模板
<T> T providerCallWithRetry(ProviderKey key, Function<IContentProvider,T> f) {
  IContentProvider p = acquireProvider(key);
  try {
    return f.apply(p);
  } catch (DeadObjectException e) {
    releaseProvider(p);
    p = acquireProvider(key);
    return f.apply(p);
  }
}
```

### 4.3 AOSP 代码路径（Android 12）

- `android.os.ServiceManager`：`sCache`
- `android.app.ContextImpl`：`mServiceCache`
- `android.app.ActivityThread`：`mProviderMap` / `ProviderClientRecord`
- `android.content.ContentResolver`：provider 获取/缓存
- `com.android.server.AlarmManagerService`
- `com.android.server.job.JobSchedulerService` / `JobStore`
- `com.android.server.am.ContentProviderHelper`

### 4.4 工作量估计

**Medium（1–2 天）**
---

## 5. ConnectivityManager / LocationManager / SensorManager 状态恢复

### 5.1 问题分析

应用进程里缓存的 system service Binder 句柄与"注册到系统侧的回调/监听/事件队列"都会失效：

| 服务 | 失效表现 |
|------|---------|
| **ConnectivityManager** | `IConnectivityManager` 代理失效；NetworkCallback binder token 失效，回调不再到达 |
| **LocationManager** | `ILocationManager` 代理失效；ListenerTransport binder 失效 |
| **SensorManager** | native event queue/FD 不可用；`SensorEventQueue`/`BitTube` 连接断裂 |

### 5.2 解决方案

**核心原则**：框架侧记录注册参数以便重放；系统服务侧提供按 (uid,pid,restoreEpoch) 批量清理旧状态的入口。`[Flux借鉴]` 对于 ConnectivityManager，同设备场景下也可将 restore 视为一次普通网络变化事件，利用已有的 onAvailable/onLost 回调机制简化处理。

#### 5.2.1 统一恢复点

```java
final class CriuRestoreController {
  private static final AtomicLong sEpoch = new AtomicLong(0);

  static void onCriuRestored() {
    long epoch = sEpoch.incrementAndGet();
    ServiceManagerInternal.clearCache();

    int uid = Process.myUid();
    int pid = Process.myPid();

    // 先让系统侧清理该进程旧注册
    ConnectivityManagerInternal.onProcessRestored(uid, pid, epoch);
    LocationManagerInternal.onProcessRestored(uid, pid, epoch);
    SensorManagerInternal.onProcessRestored(uid, pid, epoch);

    // 再由各 manager 重放注册
    ConnectivityManagerInternal.replayRegistrations(epoch);
    LocationManagerInternal.replayRegistrations(epoch);
    SensorManagerInternal.replayRegistrations(epoch);
  }
}
```

#### 5.2.2 Connectivity：记录 + 清理 + 重放

```java
// App side（ConnectivityManager 内部）
class NetReg { NetworkRequest req; NetworkCallback cb; Handler h; int flags; }
Map<NetworkCallback, NetReg> mRegs = new ConcurrentHashMap<>();

void registerNetworkCallback(NetworkRequest req, NetworkCallback cb, Handler h, int flags) {
  mRegs.put(cb, new NetReg(req, cb, h, flags));
  doRegister(req, cb, h, flags);
}

void replayRegistrations(long epoch) {
  for (NetReg r : mRegs.values()) {
    doRegister(r.req, r.cb, r.h, r.flags);
  }
}

// System side（ConnectivityService 内部）
void onProcessRestored(int uid, int pid, long epoch) {
  removeRequestsFor(uid, pid);
}
```

> **`[Flux借鉴]` 简化路径**：在同设备场景下，网络配置（IP/路由/DNS）不变，可在 system_server 侧仅做 `removeRequestsFor(uid, pid)` 清理旧注册后，由 App 侧正常 re-register callback，ConnectivityService 会立即向新 callback 推送当前网络状态（onAvailable），无需额外的 replay 逻辑。这比完整的记录-清理-重放更简洁。

#### 5.2.3 Location：重建 ListenerTransport

```java
// App side（LocationManager 内部）
class LocReg { LocationRequest req; LocationListener l; Looper looper; String provider; }
Map<LocationListener, LocReg> mLocRegs = new ConcurrentHashMap<>();

void replayRegistrations(long epoch) {
  for (LocReg r : mLocRegs.values()) {
    doRequest(r.provider, r.req, r.l, r.looper); // 重新创建 ListenerTransport
  }
}

// System side（LocationManagerService）
void onProcessRestored(int uid, int pid, long epoch) {
  removeAllRequestsForUidPid(uid, pid);
}
```

#### 5.2.4 Sensor：重建 native queue/connection

> **`[Flux借鉴]` 备选方案：dup2 FD 保持技巧**：Flux 论文提出通过 `dup2()` 将新建的 SensorEventQueue socket FD 映射到旧 FD 号上，使上层代码无需感知 FD 变化。但在同设备场景下，CRIU 本身就保持 FD 号不变，且 SensorService 侧的 connection 仍需重建，因此完全重建（如下）更简单可靠。

```java
// App side（SystemSensorManager 内部）
class SensorReg { Sensor s; SensorEventListener l; int rateUs; Handler h; }
Map<SensorEventListener, List<SensorReg>> mSensorRegs = new ConcurrentHashMap<>();

void replayRegistrations(long epoch) {
  // 关键：丢弃旧 SensorEventQueue，强制新建
  destroyAllQueues();
  for (List<SensorReg> regs : mSensorRegs.values()) {
    for (SensorReg r : regs) doRegisterImpl(r.s, r.l, r.rateUs, r.h);
  }
}

// System side（SensorService）
void onProcessRestored(int uid, int pid, long epoch) {
  disconnectAllConnectionsForUidPid(uid, pid);
}
```

### 5.3 注意事项

- **无法主动 unregister 旧 token**：旧 callback/listener 的 Binder token 恢复后通常无法被系统侧匹配，需要系统侧按 uid/pid 批量清理
- **后台/权限/模式变化**：恢复点重放注册可能因权限撤销、后台定位限制失败，要允许失败并向上层暴露状态
- **并发与重复注册**：恢复点与业务线程可能同时 register/unregister，注册表要线程安全

### 5.4 AOSP 代码路径（Android 12）

**网络**：
- `frameworks/base/core/java/android/net/ConnectivityManager.java`
- `frameworks/base/services/core/java/com/android/server/ConnectivityService.java`

**定位**：
- `frameworks/base/location/java/android/location/LocationManager.java`
- `frameworks/base/services/core/java/com/android/server/location/LocationManagerService.java`

**传感器**：
- `frameworks/base/core/java/android/hardware/SystemSensorManager.java`
- `frameworks/base/core/jni/android_hardware_SensorManager.cpp`
- `frameworks/native/services/sensorservice/SensorService.cpp`

### 5.5 工作量估计

**Medium（1–2 天）**
---

## 6. NotificationManager / MediaSession / InputMethodManager 状态恢复

### 6.1 NotificationManagerService (NMS)

#### 6.1.1 问题分析

| 状态 | 失效表现 |
|------|---------|
| 已发布通知集合 (`NotificationRecord`) | App 认为通知还在，但已被用户划掉/系统取消 |
| Ranking/Signals | 排序与重要性重新计算，App 本地缓存不可信 |
| 气泡与分组 | BubbleController/group summary 状态可能被改写 |
| Snooze 状态 | 对"是否 snoozed、剩余多久"判断错误 |
| NotificationListenerService 绑定 | 已连接但收不到回调/回调状态错乱 |
| PendingIntent 身份 | 点击跳转到"新/旧"逻辑不一致 |

#### 6.1.2 解决方案

**核心原则**：以 App 为源（checkpoint 时刻）做"重放 + 对账"。

```java
class NotifSnapshot {
    long checkpointWallTimeMs;
    Map<String, NotifSpec> notifs; // key: tag|id
    boolean strictReconcile;
}

class NotifSpec {
    String tag; int id;
    String channelId;
    boolean ongoing, onlyAlertOnce;
    long whenMs, timeoutAfterMs;
    Bundle builderArgs;
    PendingIntentSpec contentIntent;
    List<PendingIntentSpec> actionIntents;
}

void onPostRestore_ReconcileNotifications(Context ctx, NotifSnapshot snap) {
    NotificationManager nm = ctx.getSystemService(NotificationManager.class);

    // 1) 拉取 NMS 当前仍存在的本包通知
    Map<String, StatusBarNotification> active = new HashMap<>();
    for (StatusBarNotification sbn : nm.getActiveNotifications()) {
        active.put(sbn.getTag() + "|" + sbn.getId(), sbn);
    }

    // 2) 按快照重放
    for (NotifSpec spec : snap.notifs.values()) {
        Notification rebuilt = rebuildNotificationFromSpec(ctx, spec)
            .setOnlyAlertOnce(true)
            .build();
        nm.notify(spec.tag, spec.id, rebuilt);
    }

    // 3) 严格一致：取消快照外的"未来通知"
    if (snap.strictReconcile) {
        for (String key : active.keySet()) {
            if (!snap.notifs.containsKey(key)) {
                // cancel...
            }
        }
    }

    // 4) 若 App 是 NLS：请求重绑
    if (appImplementsNls()) {
        NotificationListenerService.requestRebind(new ComponentName(ctx, MyNls.class));
    }
}
```

#### 6.1.3 AOSP 代码路径

- `frameworks/base/services/core/java/com/android/server/notification/NotificationManagerService.java`
- `frameworks/base/services/core/java/com/android/server/notification/NotificationRecord.java`
- `frameworks/base/services/core/java/com/android/server/notification/NotificationListeners.java`

#### 6.1.4 工作量估计

**Medium（1–2 天）**

---

### 6.2 MediaSession / AudioFocus

#### 6.2.1 问题分析

| 状态 | 失效表现 |
|------|---------|
| MediaSession 运行态 | system_server/UI/蓝牙看到的状态与 App 不一致 |
| Transport controls | 按键无效、显示信息不更新 |
| Audio focus 栈 | App 以为自己持有 focus，实际已被抢走 |

#### 6.2.2 解决方案

**Session 采用"重推状态"**，**Audio focus 采用"幂等重申请"**：

```java
class MediaSnapshot {
    boolean sessionActive;
    PlaybackStateCompatSnapshot playback;
    MediaMetadataCompatSnapshot metadata;
    AudioFocusSnapshot focus;
}

void onPostRestore_RecoverMedia(MediaSnapshot snap) {
    // 1) MediaSession：重推状态
    MediaSession session = mediaSessionSingleton();
    session.setActive(snap.sessionActive);
    session.setMetadata(buildMetadata(snap.metadata));
    session.setPlaybackState(buildPlaybackState(
        snap.playback.state,
        estimatePositionAfterRestore(snap.playback),
        snap.playback.speed,
        SystemClock.elapsedRealtime()
    ));

    // 2) Audio focus：按快照重申请
    if (snap.focus.hadFocusAtCheckpoint) {
        AudioFocusRequest afr = new AudioFocusRequest.Builder(snap.focus.focusGain)
            .setAudioAttributes(snap.focus.attrs)
            .setOnAudioFocusChangeListener(this::onFocusChanged)
            .build();
        int r = audioManager.requestAudioFocus(afr);
        if (r != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
            handleNoFocus();
        }
    }
}
```

#### 6.2.3 AOSP 代码路径

- `frameworks/base/services/core/java/com/android/server/media/MediaSessionService.java`
- `frameworks/base/media/java/android/media/session/MediaSession.java`
- `frameworks/base/services/core/java/com/android/server/audio/AudioService.java`
- `frameworks/base/services/core/java/com/android/server/audio/MediaFocusControl.java`

#### 6.2.4 工作量估计

**Short（1–4 小时）到 Medium**

---

### 6.3 InputMethodManager (IMM)

#### 6.3.1 问题分析

| 状态 | 失效表现 |
|------|---------|
| 当前输入绑定/会话 | 软键盘显示但输入不进来 |
| EditorInfo | 选区/光标更新不再生效 |
| IME 可见性 | 系统已隐藏，App 认为应显示 |

#### 6.3.2 解决方案

**App 侧：强制重建输入链路**：

```java
class ImeSnapshot {
    boolean shouldBeVisibleAtCheckpoint;
    int focusedViewId;
}

void onPostRestore_RecoverIme(Activity activity, ImeSnapshot snap) {
    View root = activity.getWindow().getDecorView();
    View focused = root.findFocus();
    if (focused == null && snap.focusedViewId != View.NO_ID) {
        focused = root.findViewById(snap.focusedViewId);
        if (focused != null) focused.requestFocus();
    }
    if (focused == null) return;

    InputMethodManager imm = activity.getSystemService(InputMethodManager.class);

    // 1) 强制重启输入
    imm.restartInput(focused);

    // 2) 对齐可见性
    if (snap.shouldBeVisibleAtCheckpoint) {
        imm.showSoftInput(focused, InputMethodManager.SHOW_IMPLICIT);
    } else {
        IBinder token = focused.getWindowToken();
        if (token != null) imm.hideSoftInputFromWindow(token, 0);
    }
}
```

**system_server 侧建议补丁**：当收到"该 app 进程已 restore"信号时，对 `ClientState` 做一次"解绑/清会话"。

#### 6.3.3 AOSP 代码路径

- `frameworks/base/services/core/java/com/android/server/inputmethod/InputMethodManagerService.java`
- `frameworks/base/core/java/android/view/inputmethod/InputMethodManager.java`

#### 6.3.4 工作量估计

**Medium（1–2 天）**

---

## 7. PackageManager / 权限 / AppOps 状态校验

### 7.1 问题分析

| 状态 | 失效表现 |
|------|---------|
| PackageSetting / UID | uid/appId 变化，安全边界破坏 |
| 组件启用状态 | App 缓存旧 PackageInfo，实际已被禁用 |
| 运行时权限 | 权限被撤销，App 仍缓存"已授予列表" |
| AppOpsService 状态 | 策略变化，长生命周期 op 已超时 |
| 共享库/依赖 | 包更新导致 splits/classloader context 变化 |
| 版本期望 | versionCode/签名变化 |

### 7.2 解决方案

**主原则：只做"可证明安全的和解"，否则重启。**

#### 7.2.1 包完整性校验（硬门槛）

比较 pre-dump 记录与 post-restore 实际：
- `uid`、`signing cert digest`、`longVersionCode`、`lastUpdateTime`、`splits/shared libs 摘要`
- 任一关键不一致 → `UNRECOVERABLE`，kill 并由 AMS 正常冷启动

#### 7.2.2 伪代码

```java
struct PkgSnapshot {
    String packageName;
    int userId, uid;
    long longVersionCode, lastUpdateTime;
    byte[] signingCertSha256;
    byte[] enabledStateDigest;
    byte[] runtimePermDigest;
    byte[] appOpsDigest;
    byte[] sharedLibDigest;
}

enum ReconcileResult { OK, SOFT_CHANGED, UNRECOVERABLE }

ReconcileResult reconcilePkgState(PkgSnapshot snapshot) {
    // UID 检查
    if (PMS.getPackageUid(snapshot.packageName, snapshot.userId) != snapshot.uid) {
        return UNRECOVERABLE;
    }

    // 签名检查
    if (digest(curPkg.signingInfo) != snapshot.signingCertSha256) {
        return UNRECOVERABLE;
    }

    // 版本/依赖检查
    if (curPkg.longVersionCode != snapshot.longVersionCode ||
        curPkg.lastUpdateTime != snapshot.lastUpdateTime) {
        return UNRECOVERABLE;
    }

    // 软变化：组件开关/权限/AppOps
    boolean soft = false;
    if (digest(PMS.readComponentEnabledState(...)) != snapshot.enabledStateDigest) soft = true;
    if (digest(PERM.readRuntimeGrants(...)) != snapshot.runtimePermDigest) soft = true;

    if (soft) {
        Orchestrator.notifyApp(snapshot.uid, "PM_PERM_APPOPS_CHANGED");
        return SOFT_CHANGED;
    }

    return OK;
}
```

### 7.3 边界情况处理

| 场景 | 处理 |
|------|------|
| 冻结期间包被更新 | `UNRECOVERABLE` → kill 并正常冷启动 |
| 权限被撤销 | 允许 restore 继续，但 App 进入"最小权限模式" |
| 应用被禁用 | kill 并不再恢复该会话 |

### 7.4 AOSP 代码路径

- `frameworks/base/services/core/java/com/android/server/pm/PackageManagerService.java`
- `frameworks/base/services/core/java/com/android/server/pm/Settings.java`
- `frameworks/base/services/core/java/com/android/server/appop/AppOpsService.java`
- `frameworks/base/services/core/java/com/android/server/pm/permission/PermissionManagerService*.java`

---

## 8. 验证与测试矩阵

### 8.1 功能回归矩阵

| 测试项 | 验证点 |
|--------|--------|
| 前台 Activity | 交互/旋转/切后台再回前台 |
| started service | 多次 startService args；不丢/不重复 |
| bound service | 多 client 绑定/解绑；onServiceConnected 次数一致 |
| FGS | 进入/退出前台服务；状态与通知一致 |
| 广播 | 动态注册 + 有序/并行广播；不跳 receiver、不重复 finish |
| ContentProvider | 并发 query/insert；无 DeadObjectException |
| 通知 | 快照恢复后重放；NLS 重绑 |
| MediaSession | 播放状态同步；焦点重申请 |
| IME | 输入连接重建；可见性对齐 |

### 8.2 可观测性

- 新增 `dumpsys activity criu`：输出 frozen 会话、checkpointId、defer 队列长度、thaw 次数
- restore 前后对比：`dumpsys activity processes/services/broadcasts/providers`

### 8.3 稳定性测试

- 连续 N 次（如 50 次）checkpoint/restore
- 记录：成功率、平均冻结时长、defer 次数、ANR 数

---

## 9. 与 Flux 论文方案的对比分析

> Flux 是一篇研究 Android 应用跨设备迁移的论文，提出了 **Selective Record / Adaptive Replay + CRIA（Checkpoint/Restore in Android）** 方案。本节将 Flux 方案与本文档的 Quiesce/Rebind 框架进行系统对比，并据此改进本方案。

### 9.1 架构层面对比

| 维度 | 本方案（Quiesce/Rebind） | Flux（Selective Record/Adaptive Replay） |
|------|------------------------|----------------------------------------|
| **应用场景** | 同设备快照/恢复（ReDroid 容器） | 跨设备实时迁移 |
| **checkpoint 范围** | 仅 App 进程（CRIU），system_server 不参与 | App 进程（CRIA），system_server 不 checkpoint 但被装饰 |
| **核心机制** | Quiesce → Dump → Restore → Rebind 四阶段 + RestoreOrchestratorService 编排 | 预处理（push to background → release device state）→ CRIA checkpoint → restore → replay |
| **system_server 改动方式** | 新增 AIDL 接口 + freeze/defer 协议 + RestoreModule 模块 | Decorator 注解标记方法（@record/@drop/@if/@replayproxy） |
| **状态恢复哲学** | "尽量原位保留，精确重连" | "放弃设备相关状态，通过重放自然重建" |
| **冻结期处理** | 显式 defer 队列（broadcast/service/provider） | 无需——已将 app 推至 stopped 状态，不会有新交互 |
| **编排方式** | 集中式编排器 + 拓扑排序依赖图 | 分布式 decorator，由各服务自行处理 |
| **代码侵入性** | 需修改 AOSP framework 多处（AMS/WMS/PMS 等） | 同样修改 AOSP，但以 decorator 形式，更局部化 |

### 9.2 服务级别对比

| 系统服务 | 本方案 | Flux | 对比分析 |
|----------|--------|------|----------|
| **AMS** | prepareCriuCheckpoint/notifyCriuRestored AIDL；冻结期 defer broadcast/service/provider；刷新 pid/thread 映射 | 不迁移 ProcessRecord；用 wrapper app 在目标设备通过 private PID namespace 重新 attachApplication | 本方案更完整：同设备可保留 ProcessRecord 并精确刷新；Flux 的 wrapper app 方式适合跨设备但丢失更多状态 |
| **WMS/SurfaceFlinger** | restoreId 逻辑身份 + 窗口级重连 reconnectWindow()；重建 SurfaceControl/InputChannel；保留窗口位置和层级 | 完全销毁渲染状态（destroyHardwareResources + eglUnloadLibrary）；恢复后由 Activity resume 自然重建 | 本方案保留更多 UI 状态（窗口位置、z-order），但工程复杂度高；**Flux 的「销毁-重建」可作为 fallback 方案** |
| **AlarmManager** | App 侧持久化闹钟期望态 + 幂等重放；DeadObject 重连 | @record set/setExact；checkpoint-time 对账（triggerAtTime ≤ checkpointTime → 跳过）；@replayproxy 重放 | 类似。**Flux 的 checkpoint-time 对账逻辑值得采纳**——避免重放已过期闹钟 |
| **JobScheduler** | 完整支持：重注册 + jobId 覆盖式幂等 | **未支持**（未装饰） | 本方案优势。Flux 的缺失说明 Job 的跨设备迁移本身意义有限（设备条件变化），但同设备场景下有必要 |
| **ContentProvider** | 完整支持：quiesce 时关闭 cursor；恢复后 provider map 清空 + DeadObject retry | **不支持**（明确排除） | 本方案优势。对容器场景而言 Provider 连接恢复是必须的 |
| **ConnectivityManager** | 记录注册参数 + 系统侧 uid/pid 清理 + 重放 | 将迁移视为一次"网络变化事件"；自然触发 onAvailable/onLost 回调；~59 LOC | 两者都可行。**Flux 的「视为网络变化」思路更简洁**——同设备场景下 IP/网络配置不变，可简化处理 |
| **LocationManager** | 记录 + 系统侧清理 + 重放 ListenerTransport | @record requestLocationUpdates；@drop removeUpdates；@replayproxy 重放；~45 LOC | 高度相似。Flux 的 decorator 方式更紧凑 |
| **SensorManager** | 销毁旧 SensorEventQueue + 全量重注册 | **dup2 技巧**：保持 socket descriptor 编号不变，重连 native sensor connection | 方向不同。**Flux 的 dup2 技巧值得研究**——同设备场景下 FD 号可由 CRIU 保持，可能省去完全重建的开销 |
| **NotificationManager** | NotifSnapshot 快照 + 重放 + 严格对账模式 + NLS 重绑 | @record notify；@drop cancel；恢复后重放活跃通知；~40 LOC | 本方案更完整（处理 NLS、bubbles、snooze、ranking）。Flux 的 @record/@drop 模式更简洁 |
| **MediaSession/AudioFocus** | MediaSnapshot + 重推状态 + 幂等重申请焦点 | @record setActive/setMetadata/setPlaybackState；@record requestAudioFocus；~150 LOC | 高度相似 |
| **InputMethodManager** | restartInput + 可见性对齐 + system_server 侧 ClientState 清理 | force hide → restore → reshow；~30 LOC | 高度相似。Flux 的 force-hide-first 策略可简化恢复 |
| **PackageManager/权限/AppOps** | 完整校验：uid/签名/版本/权限/AppOps 摘要对比；硬门槛 UNRECOVERABLE | **未涉及** | 本方案优势。跨设备场景下包管理由安装流程保证；同设备快照场景需要显式校验 |

### 9.3 Flux 方案的核心优势

1. **Decorator 模式侵入性低**：通过 @record/@drop/@if/@replayproxy 标注系统服务方法，无需改变控制流，各服务独立改动，适合增量开发
2. **"放弃设备状态" 哲学简化了 WMS/SurfaceFlinger 处理**：不尝试保留渲染管线状态，而是让 Activity 自然重建，大幅降低工程复杂度
3. **Checkpoint-time 对账**：对 AlarmManager 的过期闹钟跳过逻辑简洁有效
4. **SensorManager dup2 技巧**：通过保持 socket FD 号不变实现底层连接复用，避免完全重建
5. **将网络恢复视为普通网络变化**：ConnectivityManager 不需要特殊处理，利用已有的网络状态变化回调机制

### 9.4 Flux 方案的局限（相对于本方案）

1. **不支持 JobScheduler 和 ContentProvider**：这两个服务在容器快照场景中不可或缺
2. **不支持多进程应用**：Flux 限制为单进程 app
3. **WMS 完全销毁策略**：丢失窗口位置、大小、z-order 等状态，用户体验不如精确重连
4. **无冻结期 defer 机制**：Flux 假设 app 已被推至 stopped 状态，不处理冻结期间 system_server 主动推送的事件；在同设备场景中，短暂冻结期间仍可能有 broadcast/service 调度
5. **缺少 PackageManager/权限校验**：同设备恢复可能面临冻结期间的包更新或权限撤销
6. **跨设备复杂性**：需要处理设备异构性（屏幕尺寸、传感器差异等），这些在同设备场景中不存在

### 9.5 据此对本方案的改进

基于以上对比分析，本方案做如下改进（标记 `[Flux借鉴]`）：

#### 9.5.1 AlarmManager：增加 checkpoint-time 对账逻辑

在 §4.2.2 的闹钟重放逻辑中，增加过期闹钟跳过：

```java
// [Flux借鉴] Alarm reconciliation with checkpoint-time filtering
void onCriuRestored(long checkpointUptimeMs) {
    long checkpointWallTimeMs = convertUptimeToWallTime(checkpointUptimeMs);
    List<AlarmSpec> specs = loadFromDisk();
    for (AlarmSpec s : specs) {
        // [Flux借鉴] 跳过在 checkpoint 之前已经到期的闹钟
        if (s.triggerAtMillis <= checkpointWallTimeMs) {
            Log.d(TAG, "Skipping expired alarm: " + s.requestCode);
            continue;
        }
        PendingIntent pi = PendingIntent.getBroadcast(
            ctx, s.requestCode, s.intent, FLAG_UPDATE_CURRENT | FLAG_IMMUTABLE);
        alarmManager.setExactAndAllowWhileIdle(s.type, s.triggerAtMillis, pi);
    }
}
```

#### 9.5.2 SensorManager：评估 dup2 FD 保持技巧

在 §5.2.4 中补充 Flux 的 dup2 方案作为优化选项：

```java
// [Flux借鉴] 方案 B：dup2 保持 socket FD 号不变
// 原理：SensorEventQueue 底层使用 AF_UNIX socketpair（BitTube），
//        CRIU 恢复后 FD 号不变但 socket 对端（SensorService）已断开。
//        通过 dup2 将新建连接的 FD 映射到旧 FD 号上，上层代码无需感知。
//
// 适用性分析：
//   - 同设备场景优势：CRIU 本身会保持 FD 号，减少一步 dup2
//   - 但 SensorService 侧的 connection 仍需重建
//   - 评估结论：同设备场景下，完全重建（方案 A）更简单可靠；
//     dup2 技巧更适合需要保持 native 层 FD 引用不变的场景
```

#### 9.5.3 ConnectivityManager：增加「视为网络变化」的简化路径

在 §5.2.2 中补充：

```java
// [Flux借鉴] 简化路径：将 restore 视为一次网络变化事件
// 在同设备场景下，IP 和网络配置不变，可以利用 ConnectivityService
// 已有的 onAvailable/onLost/onCapabilitiesChanged 回调机制。
// 具体做法：在 system_server 侧触发一次网络状态刷新，让已注册的
// NetworkCallback 自然收到回调，无需显式重放注册。
//
// 实现：
void onProcessRestored_simplified(int uid, int pid, long epoch) {
    // 只需清理旧注册（binder token 已失效）
    removeRequestsFor(uid, pid);
    // 触发一次网络状态通知，让新注册的 callback 立即收到当前状态
    notifyNetworkStateForNewCallbacks(uid);
}
```

#### 9.5.4 WMS/SurfaceFlinger：增加「销毁-重建」作为 fallback 方案

在 §3.2 的方案选项表中已有类似选项（方案 A：直接重启 Activity），但 Flux 的方式更精细——不重启 Activity 而是只销毁渲染资源：

```java
// [Flux借鉴] Fallback 方案：销毁渲染状态 + 自然重建
// 当 restoreId 重连方案失败时的降级策略：
void fallbackDestroyAndRebuild(Activity activity) {
    // 1) 销毁硬件渲染资源（同 Flux 的 destroyHardwareResources）
    activity.getWindow().getDecorView().destroyHardwareResources();

    // 2) 强制 invalidate 整个视图树
    View root = activity.getWindow().getDecorView();
    root.invalidate();

    // 3) 触发 ThreadedRenderer 重建管线
    // Activity 的下一次 performTraversals() 会自然重建 Surface + EGL
}
```

#### 9.5.5 Decorator 模式的启发：RestoreModule 接口增强

Flux 的 decorator 思想启发我们让 RestoreModule 更声明式：

```java
// [Flux借鉴] 增强 RestoreModule 接口，支持声明式状态分类
interface RestoreModule {
    String name();
    List<String> dependsOn();
    Result preDump(Session s);
    Result postRestore(Session s);
    boolean required();

    // [Flux借鉴] 新增：声明该模块管理的状态类别
    default StateCategory stateCategory() {
        return StateCategory.REQUIRES_RECONNECT;
    }

    enum StateCategory {
        DEVICE_BOUND,       // 设备绑定状态，需销毁后重建（GPU/Camera/Sensor）
        REQUIRES_RECONNECT, // 需要主动重连（AMS/WMS/Notification）
        IDEMPOTENT_REPLAY,  // 可幂等重放（Alarm/Job/Location）
        VERIFY_ONLY         // 仅需校验（PMS/Permission）
    }
}
```

### 9.6 总结：两种方案互补性

| 维度 | 本方案更优 | Flux 更优 | 互补点 |
|------|-----------|-----------|--------|
| 服务覆盖 | JobScheduler、ContentProvider、PMS/权限 | — | Flux 未覆盖的服务仍需本方案处理 |
| AMS 处理 | 冻结期 defer 协议更完整 | — | — |
| WMS 处理 | 窗口状态精确保留 | 销毁-重建更简单 | 两者互补：精确重连为主，销毁-重建为 fallback |
| AlarmManager | — | checkpoint-time 对账 | 已采纳到本方案 |
| SensorManager | — | dup2 FD 技巧 | 已评估，同设备场景下完全重建更适合 |
| Connectivity | — | 视为网络变化事件 | 已采纳简化路径 |
| 工程模式 | 集中编排，依赖可控 | decorator 分布式，侵入低 | StateCategory 声明式增强 |
| 适用场景 | 同设备容器 | 跨设备迁移 | 核心机制可互相借鉴 |

## 附录：状态一致性总结表

| 系统服务 | 严重度 | CRIU 覆盖 | 需要自定义处理 | 恢复方式 | Flux 对比 |
|----------|--------|-----------|---------------|----------|-----------|
| **AMS** | P0 | No | 是 | Quiesce + Reattach 协议 | 本方案更完整（保留 ProcessRecord） |
| **WMS/SurfaceFlinger** | P0/P1 | No | 是 | 重建 Surface/EGL；`[Flux]` 销毁-重建为 fallback | Flux 更简单但丢失窗口状态 |
| **AlarmManager** | P1 | No | 是 | 快照 + 重调度 + `[Flux]` checkpoint-time 过期过滤 | 已采纳 Flux 过期闹钟跳过逻辑 |
| **JobScheduler** | P1 | No | 是 | 重注册 + 幂等键 | Flux 未覆盖 |
| **ContentProvider** | P1 | Partial | 是 | quiesce 时关闭 cursor，恢复后重查询 | Flux 未覆盖 |
| **Connectivity/NetworkCallback** | P1 | No | 是 | 重注册回调 + `[Flux]` 可视为网络变化事件简化 | 已采纳简化路径 |
| **LocationManager** | P1 | No | 是 | 重请求更新 | 两者高度相似 |
| **SensorManager** | P1 | No | 是 | 重注册监听（完全重建优于 Flux dup2） | 已评估 Flux dup2，不采纳 |
| **NotificationManager** | P1/P2 | No | 是 | 重放通知账本 | 本方案更完整（NLS/bubble/snooze） |
| **MediaSession/AudioFocus** | P1 | No | 是 | 重推状态 + 重申请焦点 | 两者高度相似 |
| **InputMethodManager** | P1 | No | 是 | restartInput + 可见性对齐 | 两者高度相似 |
| **PackageManager/权限** | P0/P1 | No | 是 | 校验 + 对账 | Flux 未覆盖 |
| **ashmem/memfd** | P0 | Partial/No | 是 | 自定义 dump/restore | Flux 未涉及 |
| **设备 FD (GPU/camera/audio)** | P0 | No | 是 | dump 前关闭，恢复后重建 | Flux 采用完全销毁策略 |

---

*文档版本：v1.2*
*最后更新：2026-03-11*
*状态：已完成所有章节，含 Flux 论文对比分析及方案改进*
