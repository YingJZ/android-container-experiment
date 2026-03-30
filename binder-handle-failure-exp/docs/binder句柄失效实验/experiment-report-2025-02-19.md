# Binder 句柄失效实验报告

**日期：** 2025-02-19  
**实验者：** Ying Jiaze  
**实验方法：** Docker commit 快照/恢复

## 实验环境

| 项目 | 配置 |
|------|------|
| 容器镜像 | redroid/redroid:12.0.0_64only-latest |
| 容器名称 | redroid-experiment |
| ADB 端口 | 5555 |
| 测试应用 | BinderTestApp (debug) |
| 快照方式 | Docker commit |

## 实验步骤

### 1. 环境验证

```bash
# 检查容器状态
$ sudo docker ps
NAMES                 STATUS       PORTS
redroid-experiment    Up 2 hours   0.0.0.0:5555->5555/tcp

# 检查 ADB 连接
$ adb devices
localhost:5555    device
```

### 2. 安装测试应用

```bash
$ adb -s localhost:5555 install test-app/BinderTestApp/app/build/outputs/apk/debug/app-debug.apk
Success

$ adb -s localhost:5555 shell pm list packages | grep bindertest
package:com.experiment.bindertest
```

### 3. 快照前测试

```bash
# 启动应用
$ adb -s localhost:5555 shell am start -n com.experiment.bindertest/.MainActivity

# 触发 Binder 测试
$ adb -s localhost:5555 shell am broadcast \
    -a com.experiment.bindertest.TEST_BINDER \
    -n com.experiment.bindertest/.BinderTestReceiver
```

**测试日志：**

```
02-19 14:34:35.449  1855  1855 I BinderTestReceiver: 收到广播: com.experiment.bindertest.TEST_BINDER
02-19 14:34:35.450  1855  1855 I BinderTestReceiver: ========== 开始 Binder 测试 ==========
02-19 14:34:35.450  1855  1855 I BinderTestReceiver: ✓ ActivityManager 测试通过
02-19 14:34:35.457  1855  1855 I BinderTestReceiver: ✓ PackageManager 测试通过
02-19 14:34:35.460  1855  1855 I BinderTestReceiver: ✓ ServiceManager 测试通过
02-19 14:34:35.462  1855  1855 I BinderTestReceiver: ✓ ContentResolver 测试通过
02-19 14:34:35.462  1855  1855 I BinderTestReceiver: ========== 测试完成 ==========
02-19 14:34:35.462  1855  1855 I BinderTestReceiver: 结果: 成功=4, 失败=0
```

**快照前测试结果：**

| 测试项 | 结果 |
|--------|------|
| ActivityManager | ✓ 通过 |
| PackageManager | ✓ 通过 |
| ServiceManager | ✓ 通过 |
| ContentResolver | ✓ 通过 |

### 4. 创建快照

```bash
$ sudo docker commit redroid-experiment redroid-experiment:snapshot-experiment2
sha256:c4321bac155c...

$ sudo docker images | grep redroid-experiment
redroid-experiment    snapshot-experiment2    c4321bac155c   1.52GB
```

### 5. 停止并恢复容器

```bash
# 停止原容器
$ sudo docker stop redroid-experiment
$ sudo docker rm redroid-experiment

# 从快照恢复
$ sudo docker run -d --name redroid-experiment --privileged \
    -p 5555:5555 \
    redroid-experiment:snapshot-experiment2
```

### 6. 恢复后测试

```bash
# 重新连接 ADB
$ sleep 25 && adb connect localhost:5555

# 验证应用仍安装
$ adb -s localhost:5555 shell pm list packages | grep bindertest
package:com.experiment.bindertest

# 触发 Binder 测试
$ adb -s localhost:5555 shell am broadcast \
    -a com.experiment.bindertest.TEST_BINDER \
    -n com.experiment.bindertest/.BinderTestReceiver
```

**测试日志：**

```
02-19 14:36:05.401  1498  1498 I BinderTestReceiver: 系统启动完成，执行 Binder 测试
02-19 14:36:05.401  1498  1498 I BinderTestReceiver: ========== 开始 Binder 测试 ==========
02-19 14:36:05.401  1498  1498 I BinderTestReceiver: ✓ ActivityManager 测试通过
02-19 14:36:05.412  1498  1498 I BinderTestReceiver: ✓ PackageManager 测试通过
02-19 14:36:05.413  1498  1498 I BinderTestReceiver: ✓ ServiceManager 测试通过
02-19 14:36:05.415  1498  1498 I BinderTestReceiver: ✓ ContentResolver 测试通过
02-19 14:36:05.415  1498  1498 I BinderTestReceiver: ========== 测试完成 ==========
02-19 14:36:05.416  1498  1498 I BinderTestReceiver: 结果: 成功=4, 失败=0
```

**恢复后测试结果：**

| 测试项 | 结果 |
|--------|------|
| ActivityManager | ✓ 通过 |
| PackageManager | ✓ 通过 |
| ServiceManager | ✓ 通过 |
| ContentResolver | ✓ 通过 |

## 实验结论

### 结果：未能复现 Binder 句柄失效问题

使用 Docker commit 方式进行快照/恢复后，所有 Binder 测试均通过，未能复现预期的问题。

### 原因分析

Docker commit 只保存**文件系统状态**，不保存**进程状态**：

| 快照方式 | 保存内容 | 进程状态 | Binder 句柄 |
|----------|----------|----------|-------------|
| Docker commit | 文件系统 | 重启 | 重新建立（正常）|
| CRIU checkpoint | 进程内存 | 保持 | 保留原有句柄（可能失效）|

从 Docker commit 恢复的容器，所有进程都是重新启动的，因此 Binder 句柄会重新建立，不存在失效问题。

### 正确的复现方法

要真正复现 Binder 句柄失效问题，需要使用 **CRIU (Checkpoint/Restore In Userspace)**：

1. 在主机安装 CRIU
2. 在容器内安装 CRIU
3. 使用 `docker checkpoint` 命令保存进程状态
4. 使用 `docker restore` 恢复进程状态

这样进程会在恢复后继续使用原有的 Binder 句柄，而句柄可能已经失效。

## 环境检查

```bash
# 主机 CRIU
$ which criu
CRIU not installed on host

# Docker CRIU 支持
$ docker info | grep -i criu
Docker CRIU support not found

# 容器内 CRIU
$ sudo docker exec redroid-experiment which criu
CRIU not installed in container
```

## CRIU 与 Binder 句柄的理论分析

经过进一步研究 CRIU 官方文档和相关资料，发现 **CRIU 也无法直接复现 Binder 句柄失效问题**。

### CRIU 对字符设备的限制

根据 CRIU 官方文档 [What cannot be checkpointed](https://criu.org/What_cannot_be_checkpointed)：

> "If a task has opened or mapped any character or block device, this typically means, it wants some connection to the hardware... App might have loaded some state into it, and in order to dump it properly we need to fetch that state. This is not something that can be done in a generic manner."

**结论：CRIU 会拒绝 checkpoint 打开了字符设备的进程。**

### Binder 的架构特性

Binder 是一个字符设备 `/dev/binder`，其架构如下：

```
┌─────────────────────────────────────────────────────────────┐
│                      用户空间                                │
│  ┌─────────────────┐                                        │
│  │   App 进程      │                                        │
│  │  - Binder 句柄   │  (仅保存数值，如 handle=1, 2, 3...)    │
│  │  - mmap 区域    │                                        │
│  └────────┬────────┘                                        │
│           │ ioctl() / mmap()                                │
└───────────┼─────────────────────────────────────────────────┘
            ▼
┌─────────────────────────────────────────────────────────────┐
│                      内核空间                                │
│  ┌─────────────────────────────────────────────────────┐    │
│  │              Binder 驱动                              │    │
│  │  ┌─────────────────────────────────────────────┐    │    │
│  │  │  proc_list: 进程列表                         │    │    │
│  │  │    - PID → binder_proc 映射                  │    │    │
│  │  │    - 句柄分配表                              │    │    │
│  │  │    - 引用计数                                │    │    │
│  │  │    - 挂起的事务队列                          │    │    │
│  │  └─────────────────────────────────────────────┘    │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

**Binder 句柄的本质：**

| 特性 | 说明 |
|------|------|
| 存储位置 | 内核 Binder 驱动中，非用户空间 |
| 分配机制 | 由 Binder 驱动动态分配 |
| 关联关系 | 与进程 PID、binder_proc 结构体强绑定 |
| 生命周期 | 随进程或服务端进程的生命周期 |

### CRIU 面临的技术障碍

| 层面 | 问题 | CRIU 能力 |
|------|------|-----------|
| 用户空间 | 进程内存中的句柄数值 | ✓ 可以保存 |
| 用户空间 | 打开的文件描述符 | ✓ 可以保存 |
| 内核空间 | Binder 驱动的 proc 结构 | ✗ 无法访问 |
| 内核空间 | 句柄到服务的映射关系 | ✗ 无法访问 |
| 内核空间 | 挂起的事务队列 | ✗ 无法访问 |

### 理论推演：如果强行使用 CRIU

假设绕过 CRIU 的设备检查，强行 checkpoint 一个使用 Binder 的进程：

```
Checkpoint 时:
┌─────────────────┐
│ 保存的进程状态   │
│ - 内存镜像      │
│ - Binder 句柄值  │  handle=1, 2, 3... (仅数值)
│ - 文件描述符    │
└─────────────────┘

Restore 时:
┌─────────────────┐
│ 恢复的进程      │
│ - 内存恢复      │
│ - Binder 句柄值  │  handle=1, 2, 3... (数值不变)
│ - fd 重分配     │
└─────────────────┘
         │
         ▼ ioctl(handle=1)
┌─────────────────┐
│ Binder 驱动     │
│ "PID=xxx?"      │  ← 驱动中无此进程的记录
│ "handle=1?"     │  ← 句柄映射不存在
│ → 拒绝操作      │
│ → 返回错误      │
└─────────────────┘
```

**结果：** 恢复后的进程使用旧句柄调用 Binder 时，驱动无法识别，导致 `DeadObjectException` 或其他错误。

### 结论：CRIU 不能直接复现该问题

原因：

1. **CRIU 会直接拒绝**：检测到 `/dev/binder` 字符设备，checkpoint 失败（**注：实际测试发现此结论不完全正确，见下方实际测试结果**）
2. **无 Binder 支持**：CRIU 没有实现 Binder 设备的序列化/反序列化逻辑
3. **内核状态不可达**：Binder 驱动状态在内核中，用户空间工具无法直接操作

---

## 方案 C 实际执行结果

**日期：** 2025-02-22

### CRIU 安装

从源码编译安装 CRIU 4.0：

```bash
# 安装依赖
sudo apt install -y libprotobuf-dev protobuf-c-compiler libprotobuf-c-dev \
    libnl-3-dev libnet-dev libcap-dev python3-yaml libbsd-dev protobuf-compiler

# 编译安装
git clone --depth 1 --branch v4.0 https://github.com/checkpoint-restore/criu.git
cd criu && make -j$(nproc)
sudo cp criu/criu /usr/local/bin/criu

# 验证
$ criu --version
Version: 4.0
```

### 测试 1：简单字符设备进程

创建一个打开 `/dev/null` 的测试进程：

```bash
# 编译测试程序
cat > /tmp/test_simple.c << 'EOF'
#include <unistd.h>
#include <fcntl.h>
int main() {
    int fd = open("/dev/null", O_RDWR);
    while(1) sleep(1);
    return 0;
}
EOF
gcc -o /tmp/test_simple /tmp/test_simple.c

# 运行并 checkpoint
/tmp/test_simple &
TESTPID=$!
sudo criu dump -t $TESTPID -D /tmp/criu-checkpoint --shell-job --leave-running --ext-unix-sk

# 结果：成功
$ ls /tmp/criu-checkpoint/
core-xxx.img  files.img  mm-xxx.img  pages-1.img  ...

# 恢复测试
sudo kill -9 $TESTPID
sudo criu restore -D /tmp/criu-checkpoint --shell-job -d
$ pgrep test_simple
649742  # 进程恢复成功，PID 相同
```

**结论：** CRIU 可以成功 checkpoint/restore 打开普通字符设备的进程。

### 测试 2：容器内 Binder 进程

尝试 checkpoint 容器内的 servicemanager 进程（PID 18，宿主机 PID 478095）：

```bash
# 检查进程打开的 Binder 设备
$ sudo ls -la /proc/478095/fd | grep binder
lrwx------ 1 haslab haslab 64 Feb 19 14:55 3 -> /dev/binderfs/binder

# 尝试 checkpoint
$ sudo criu dump -t 478095 -D /tmp/criu-checkpoint --shell-job \
    --leave-running --network-lock skip -v4 2>&1 | grep -i binder

(00.004402) type binder source binder mnt_id 1541 s_dev 0x71 / @ ./dev/binderfs flags 0x300000
(00.006812) mnt:   [./dev/binderfs](1541->1565)
```

**关键发现：**

1. **CRIU 检测到 Binder 类型**：日志显示 `type binder`，CRIU 将 Binder 识别为一种文件系统类型
2. **没有因 Binder 设备直接失败**：CRIU 不会因为进程打开了 `/dev/binderfs/binder` 而立即拒绝
3. **实际失败原因**：Android 容器的复杂挂载结构（cgroup、overlayfs、external mounts）

```
(00.008025) Error (criu/mount.c:1088): mnt: Mount 1672 ./sys/fs/cgroup/memory 
    (master_id: 27 shared_id: 710) has unreachable sharing. Try --enable-external-masters.
```

### 尝试的选项

| 选项 | 结果 |
|------|------|
| `--network-lock skip` | 跳过网络锁定，但仍因挂载问题失败 |
| `--enable-external-masters` | 无法解决所有外部挂载问题 |
| `--skip-mnt /sys/fs/cgroup` | 导致挂载树结构不完整 |
| `--manage-cgroups=ignore` | 仍然失败 |

### 实验结论

| 原预期 | 实际结果 |
|--------|----------|
| CRIU 会因字符设备直接拒绝 | CRIU 将 Binder 识别为文件系统类型，不会立即拒绝 |
| 需要修改 CRIU 源码支持 Binder | Android 容器的挂载结构本身就导致 checkpoint 失败 |

**最终结论：**

CRIU 无法直接复现 Binder 句柄失效问题，原因并非简单地"拒绝字符设备"，而是：

1. **Android 容器挂载结构过于复杂**：overlayfs、bind mounts、cgroup 等导致 CRIU 无法正确处理
2. **即使 checkpoint 成功**：恢复后 Binder 句柄仍可能失效，因为内核 Binder 驱动状态未被保存
3. **需要特殊处理**：要真正验证 Binder 句柄失效，需要修改 CRIU 或使用其他方法

### 真正能复现 Binder 句柄失效的方法

| 方法 | 可行性 | 说明 |
|------|--------|------|
| 修改 CRIU 源码 | 困难 | 需添加 Binder 设备的"假"支持，只保存 fd 不保存内核状态 |
| 模拟服务端死亡 | 可行 | 重启系统服务，客户端句柄失效 |
| 容器跨主机迁移 | 可行 | 不同内核的 Binder 驱动状态独立 |
| PID namespace 变化 | 可行 | Binder 驱动基于 PID 的映射失效 |

### 修正后的实验方向

**原计划：** 使用 CRIU checkpoint/restore 复现问题

**修正后：** 

1. 方法一：在容器内手动杀死系统服务进程，观察 Binder 客户端句柄失效
2. 方法二：修改测试应用，持有 Binder 句柄后休眠，外部重启容器，观察句柄失效
3. 方法三：使用不同 PID namespace 启动恢复后的容器

## 下一步计划（修正）

基于方案 C 的实际测试结果，CRIU 无法在 Android 容器环境下完成 checkpoint。

### 方案 A：模拟服务端死亡（推荐）

```bash
# 1. 启动测试应用，持有 Binder 句柄
# 2. 在容器内杀死系统服务
docker exec redroid-experiment kill <system_server_pid>

# 3. 触发测试，观察句柄失效
```

### 方案 B：修改测试应用设计

修改测试应用，使其：
1. 启动时获取并缓存 Binder 句柄
2. 在后台持续持有句柄
3. 接收广播时检查缓存句柄是否有效
4. 对比新获取的句柄

### ~~方案 C：CRIU 强制实验（探索性）~~

**已完成，结论：Android 容器的挂载结构导致 CRIU checkpoint 失败，无法用于复现 Binder 句柄失效问题。**

## CRIU 实验日志

```
=== CRIU 实验总结 ===

1. CRIU 版本: Version: 4.0

2. 简单进程测试 (打开 /dev/null):
   - Checkpoint: 成功
   - Restore: 成功

3. 容器内进程测试 (打开 /dev/binderfs/binder):
   - CRIU 检测到 binder 类型: 是
   - CRIU 直接拒绝 Binder 设备: 否
   - 失败原因: 复杂的挂载结构 (cgroup, overlayfs 等)

4. 关键发现:
   - CRIU 不会因为 Binder 字符设备本身而立即失败
   - CRIU 将 Binder 识别为一种文件系统类型 (type binder)
   - Android 容器的复杂挂载结构导致 CRIU checkpoint 失败
```

## 参考资料

- [CRIU - What cannot be checkpointed](https://criu.org/What_cannot_be_checkpointed)
- [CRIU - External resources](https://criu.org/External_resources)
- [ReDroid Documentation](https://github.com/remote-android/redroid-doc)
- [Binder IPC 机制](https://source.android.com/docs/core/architecture/hidl/binder-ipc)

## 附录：测试应用代码

测试应用位于 `test-app/BinderTestApp/`，主要测试以下 Binder 服务：

- `ActivityManager` - 应用管理服务
- `PackageManager` - 包管理服务  
- `ServiceManager` - 服务管理服务
- `ContentResolver` - 内容解析服务

应用通过 `BinderTestReceiver` 接收广播触发测试，并在日志中输出测试结果。
