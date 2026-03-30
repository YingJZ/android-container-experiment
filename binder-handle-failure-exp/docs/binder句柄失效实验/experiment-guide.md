# Binder 句柄失效实验指南

本文档详细说明如何复现 Android 容器快照恢复后 Binder 句柄失效的问题。

## 实验背景

### 什么是 Binder？

Binder 是 Android 系统的核心 IPC（进程间通信）机制。几乎所有的系统服务调用都通过 Binder 完成：

- Activity 管理
- 包管理
- 窗口管理
- 内容提供者
- 自定义 AIDL 服务

### 为什么会失效？

当容器被快照并恢复时，会发生以下情况：

1. **内核状态不持久化**
   - Binder 驱动维护的句柄表存储在内核内存中
   - 快照只保存了用户空间状态，不包含内核 Binder 驱动状态
   - 恢复后，App 持有的句柄指向不存在的内核对象

2. **引用计数丢失**
   - Binder 对象的强/弱引用计数在内核中维护
   - 恢复后引用计数不一致，导致对象被错误回收

3. **服务端重启**
   - 系统服务可能在恢复过程中重启
   - 重启后的服务获得新的 Binder 对象
   - 客户端持有的旧引用无法找到新服务

## 实验环境

### 系统要求

- Linux 服务器（Ubuntu 20.04+ 推荐）
- 内核 5.4 或更高版本
- Docker 20.10+
- 至少 8GB 内存
- 20GB 可用磁盘空间

### 检查内核模块支持

```bash
# 检查 binder 模块
modinfo binder_linux

# 检查 ashmem 模块（可选）
modinfo ashmem_linux
```

## 实验步骤

### 第一步：设置环境

```bash
# 克隆/进入项目目录
cd android-container-experiment

# 运行环境设置脚本（需要 root）
sudo ./scripts/setup-env.sh

# 验证环境
sudo ./scripts/setup-env.sh --verify
```

### 第二步：启动 ReDroid 容器

```bash
# 启动容器
./scripts/redroid-manage.sh start

# 检查状态
./scripts/redroid-manage.sh status

# 等待系统完全启动（约 1-2 分钟）
```

### 第三步：构建并安装测试应用

```bash
# 进入测试应用目录
cd test-app/BinderTestApp

# 构建（需要 Android SDK）
./gradlew assembleDebug

# 或者直接下载预编译的 APK（如果提供）

# 安装到容器
cd ../..
./scripts/redroid-manage.sh install test-app/BinderTestApp/app/build/outputs/apk/debug/app-debug.apk
```

### 第四步：启动测试应用

```bash
# 通过 ADB 启动
adb -s localhost:5555 shell am start -n com.experiment.bindertest/.MainActivity

# 或者使用 scrcpy 图形界面操作
scrcpy -s localhost:5555
```

### 第五步：开始周期测试

在应用界面中点击"开始周期测试"按钮，或通过 ADB：

```bash
# 启动周期测试
adb -s localhost:5555 shell am broadcast \
    -a com.experiment.bindertest.TEST_BINDER \
    -n com.experiment.bindertest/.BinderTestReceiver
```

### 第六步：创建快照

```bash
# 方法 1：使用 Docker commit（简单，但不完美）
./scripts/redroid-manage.sh snapshot experiment1

# 方法 2：使用 CRIU checkpoint（更完整，需要内核支持）
./scripts/checkpoint-restore.sh checkpoint experiment1
```

### 第七步：停止并恢复容器

```bash
# 停止容器
docker stop redroid-experiment

# 等待几秒
sleep 5

# 从快照恢复
./scripts/checkpoint-restore.sh restore-snap experiment1

# 或使用 CRIU
./scripts/checkpoint-restore.sh restore-cp experiment1
```

### 第八步：观察 Binder 状态

```bash
# 重新连接 ADB
adb connect localhost:5555

# 触发 Binder 测试
adb -s localhost:5555 shell am broadcast \
    -a com.experiment.bindertest.TEST_BINDER \
    -n com.experiment.bindertest/.BinderTestReceiver

# 查看日志
adb -s localhost:5555 logcat -d | grep -E "(BinderTest|DeadObjectException)"
```

## 预期结果

### 成功复现的迹象

1. **DeadObjectException**
   ```
   BinderTestReceiver: ✗✗✗ ActivityManager: DeadObjectException - BINDER 句柄失效!
   ```

2. **RemoteException**
   ```
   BinderTestReceiver: ✗ PackageManager: RemoteException - Transaction failed
   ```

3. **服务调用失败**
   - `getMemoryClass()` 返回异常
   - `getInstalledPackages()` 失败
   - Service 连接断开

### 可能的变体

根据快照/恢复方式的不同，可能观察到：

1. **完全失效** - 所有 Binder 调用失败
2. **部分失效** - 只有某些服务失效
3. **延迟失效** - 第一次调用成功，后续失败
4. **无失效** - 如果恢复太快或系统重新初始化

## 日志收集

```bash
# 收集所有调试信息
./scripts/collect-logs.sh all

# 快速收集
./scripts/collect-logs.sh quick

# 手动收集 Binder 状态
adb -s localhost:5555 shell cat /proc/binder/state > binder_state.txt
adb -s localhost:5555 logcat -d > logcat.txt
```

## 运行完整实验

使用自动化脚本运行完整实验：

```bash
./scripts/checkpoint-restore.sh run-experiment
```

这将自动：
1. 收集快照前状态
2. 创建快照
3. 停止容器
4. 恢复容器
5. 收集恢复后状态
6. 分析结果

## 故障排除

### 容器无法启动

1. 检查内核模块：
   ```bash
   lsmod | grep binder
   ```

2. 手动加载模块：
   ```bash
   sudo modprobe binder_linux devices="binder,hwbinder,vndbinder"
   ```

3. 检查 Docker 权限：
   ```bash
   docker info
   ```

### ADB 无法连接

1. 等待更长时间（首次启动可能需要 2-3 分钟）

2. 检查端口：
   ```bash
   netstat -tlnp | grep 5555
   ```

3. 重启 ADB：
   ```bash
   adb kill-server
   adb start-server
   adb connect localhost:5555
   ```

### CRIU checkpoint 失败

CRIU 可能因为各种原因失败：

1. 内核不支持某些功能
2. 进程使用了不可检查点的资源
3. 权限不足

使用 `docker commit` 作为替代方案。

## 下一步

复现问题后，可以研究以下解决方案：

1. **Binder 重连机制** - 检测失效并重新获取服务引用
2. **服务代理层** - 封装 Binder 调用，自动处理 DeadObjectException
3. **状态恢复协议** - 在快照前保存状态，恢复后重建连接
4. **内核层解决方案** - 修改 Binder 驱动支持状态持久化

## 参考资料

- [Android Binder 源码](https://android.googlesource.com/platform/frameworks/native/+/master/libs/binder/)
- [CRIU Documentation](https://criu.org/Main_Page)
- [ReDroid Project](https://github.com/remote-android/redroid-doc)
