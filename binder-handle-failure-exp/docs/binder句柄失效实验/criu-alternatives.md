# CRIU 安装问题及替代方案

## 问题说明

在某些 Ubuntu/Debian 版本中，CRIU 可能不在默认软件仓库中，导致安装失败：

```
E: Unable to locate package criu
```

## 好消息：CRIU 是可选的！

**你可以不使用 CRIU 也能完成 Binder 句柄失效实验**。

## 两种快照方式对比

### 方式 1: Docker Commit（推荐用于此实验）

**优点：**
- ✅ 无需额外安装
- ✅ Docker 内置功能
- ✅ 简单易用
- ✅ 足以复现 Binder 句柄失效问题

**缺点：**
- ⚠️ 只保存文件系统状态
- ⚠️ 不保存运行中的进程状态
- ⚠️ 恢复时容器会完全重启

**使用方法：**
```bash
# 创建快照
./scripts/checkpoint-restore.sh snapshot my-snapshot

# 恢复快照
./scripts/checkpoint-restore.sh restore-snap my-snapshot

# 或使用容器管理脚本
./scripts/redroid-manage.sh snapshot my-snapshot
./scripts/redroid-manage.sh restore my-snapshot
```

### 方式 2: CRIU Checkpoint（高级）

**优点：**
- ✅ 保存完整的进程状态
- ✅ 可以在检查点时刻精确恢复
- ✅ 更接近"真正的"快照

**缺点：**
- ❌ 需要内核支持（CONFIG_CHECKPOINT_RESTORE=y）
- ❌ 安装复杂
- ❌ 可能因为各种原因失败
- ❌ 对实验结果影响不大

**安装方法（如果需要）：**

```bash
# 方法 1: 从 PPA 安装（Ubuntu）
sudo add-apt-repository ppa:criu/ppa
sudo apt-get update
sudo apt-get install criu

# 方法 2: 从源码编译
git clone https://github.com/checkpoint-restore/criu
cd criu
sudo make install

# 方法 3: 使用其他发行版
# CRIU 在 Fedora/CentOS 等发行版的仓库中更常见
# sudo dnf install criu  # Fedora
# sudo yum install criu  # CentOS
```

## 为什么 Docker Commit 足够用于此实验？

Binder 句柄失效的核心问题是：

1. **容器停止** → Binder 驱动状态清空
2. **容器重启** → 新的 Binder 驱动状态
3. **App 持有旧句柄** → 调用失败

无论是 `docker commit` 还是 CRIU，只要容器经历了停止→恢复，都会触发这个问题。

## 推荐的实验流程（无 CRIU）

```bash
# 1. 启动容器
./scripts/redroid-manage.sh start

# 2. 安装并启动测试 App
./scripts/redroid-manage.sh install test-app/...
adb shell am start -n com.experiment.bindertest/.MainActivity

# 3. 开始周期测试（App 会持续调用 Binder）
# 在 App 界面点击"开始周期测试"

# 4. 创建快照（使用 docker commit）
./scripts/checkpoint-restore.sh snapshot experiment1

# 5. 停止容器
docker stop redroid-experiment

# 6. 等待几秒
sleep 5

# 7. 从快照恢复
./scripts/checkpoint-restore.sh restore-snap experiment1

# 8. 观察日志 - 应该能看到 DeadObjectException
adb logcat -d | grep -E "(BinderTest|DeadObjectException)"
```

## 验证 CRIU 是否可用（可选）

如果你想尝试使用 CRIU：

```bash
# 检查是否已安装
which criu

# 检查内核支持
sudo criu check

# 检查 Docker 是否支持
docker checkpoint --help
```

如果 `docker checkpoint` 命令不存在或报错，说明你的 Docker 版本不支持 CRIU。

## 实验脚本的智能处理

我们的脚本会自动检测 CRIU 是否可用：

- ✅ **有 CRIU**：优先使用 CRIU checkpoint
- ✅ **无 CRIU**：自动降级为 docker commit
- ✅ **CRIU 失败**：自动切换到 docker commit

所以你不需要担心！脚本会自动选择最佳方案。

## 结论

**对于此实验，不安装 CRIU 完全没问题！**

`docker commit` 方式足以复现 Binder 句柄失效问题，而且更简单可靠。
