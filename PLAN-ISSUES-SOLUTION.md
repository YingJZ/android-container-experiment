# Phase 0：使 CRIU 支持 Android 容器 Checkpoint/Restore — 问题与方案

**日期：** 2025-02-26  
**上下文：** 本文档是 `PLAN.md`（Binder C/R 内核方案）的前置阻塞项分析。在实施任何 Binder 状态保存/恢复之前，必须先解决 CRIU 无法 checkpoint Android 容器的根本问题。

---

## 1. 问题陈述

### 1.1 已知失败现象

根据 `experiment-report-2025-02-19.md` 的实际实验结果：

**环境：**
- 容器镜像：`redroid/redroid:12.0.0_64only-latest`
- 容器模式：`--privileged`
- CRIU 版本：4.0
- 内核版本：5.4.0

**关键发现：**

1. **CRIU 能识别 Binder 类型**：日志显示 `type binder source binder mnt_id 1541 s_dev 0x71`
2. **CRIU 不会因 Binder 设备直接失败**：进程打开 `/dev/binderfs/binder` 不会导致立即拒绝
3. **实际失败原因是挂载命名空间**：

```
Error (criu/mount.c:1088): mnt: Mount 1672 ./sys/fs/cgroup/memory
    (master_id: 27 shared_id: 710) has unreachable sharing.
    Try --enable-external-masters.
```

### 1.2 已尝试的选项（全部失败）

| 选项 | 结果 |
|------|------|
| `--network-lock skip` | 跳过网络锁定，但仍因挂载问题失败 |
| `--enable-external-masters` | 无法解决所有外部挂载问题 |
| `--skip-mnt /sys/fs/cgroup` | 导致挂载树结构不完整 |
| `--manage-cgroups=ignore` | 仍然失败 |

### 1.3 成功的对照实验

简单进程（打开 `/dev/null`）的 checkpoint/restore **完全成功**，证明 CRIU 基础功能正常，问题特定于 Android 容器的复杂挂载结构。

### 1.4 问题根因分析

Android 容器（ReDroid）的挂载命名空间包含以下 CRIU 难以处理的元素：

| 挂载类型 | 具体问题 | CRIU 处理能力 |
|----------|----------|---------------|
| **OverlayFS** | Docker 默认存储驱动，多层叠加 | 需要内核 ≥ 4.2-rc2（5.4.0 满足） |
| **cgroup 控制器** | 9+ 个控制器，slave/shared 传播 | `--manage-cgroups` 部分支持 |
| **bind mounts** | `/proc`、`/sys` 从宿主机绑定 | `--external mnt` 可声明 |
| **共享/从属传播** | `master_id`/`shared_id` 指向容器外 | `--enable-external-masters` 不完整 |
| **tmpfs** | Android 运行时大量使用 | CRIU 原生支持 |
| **devpts** | 伪终端 | Docker 未启用 TTY checkpoint |
| **binderfs** | `/dev/binderfs` | CRIU 识别但无法保存状态 |

**核心矛盾：** ReDroid 以 `--privileged` 模式运行，继承了宿主机的完整 cgroup 和挂载传播树，导致挂载命名空间远比普通 Docker 容器复杂。

---

## 2. 可行方案调研

### 方案 A：LXC + CRIU（推荐方案）⭐

**可行性评级：8/10**

**原理：** LXC 自 1.1.0 版本起就有原生 CRIU 集成，且 ReDroid 官方支持 LXC 部署。

**依据：**
- CRIU 官方文档将 LXC/LXD 列为 "ready" 集成状态（https://criu.org/LXC）
- ReDroid 官方提供 LXC 部署文档（https://github.com/remote-android/redroid-doc/blob/master/deploy/lxc.md）
- LXC 的挂载命名空间比 Docker 简单得多，无 OverlayFS 层叠

**实施步骤：**

```bash
# 1. 安装 LXC 和 CRIU
apt install lxc-utils criu

# 2. 加载内核模块
modprobe binder_linux devices="binder,hwbinder,vndbinder"
modprobe ashmem_linux

# 3. 从 OCI 镜像创建 LXC 容器
lxc-create -n redroid -t oci -- \
    -u docker://redroid/redroid:12.0.0_64only-latest

# 4. 配置容器（关键：简化挂载结构）
cat >> /var/lib/lxc/redroid/config <<EOF
lxc.console.path = none
lxc.tty.max = 0
lxc.apparmor.profile = unconfined
lxc.mount.entry = /home/data data none bind 0 0
EOF

# 5. 启动容器
lxc-start -n redroid

# 6. Checkpoint
lxc-checkpoint -n redroid -D /tmp/checkpoint -s -v

# 7. Restore
lxc-checkpoint -n redroid -D /tmp/checkpoint -r -v
```

**优势：**
- LXC 原生的 `lxc-checkpoint` 自动处理外部挂载声明
- 不经过 Docker daemon，减少挂载复杂性
- 容器根文件系统是平面目录，无 OverlayFS
- 社区有大量 LXC + CRIU 成功案例

**风险：**
- Binder 句柄仍会失效（这是内核级问题，不是挂载问题）
- 需要验证 ReDroid 在 LXC 下的 ADB 连通性
- GPU 加速可能无法跨 checkpoint 存活
- LXC OCI 模板可能需要额外配置

**预计工时：1-2 周**

---

### 方案 B：Podman + CRIU

**可行性评级：7/10**

**原理：** Podman 是 Docker 的替代品，对 CRIU 的支持优于 Docker。

**依据：**
- Podman 官方文档提供 checkpoint/restore 功能（https://podman.io/docs/checkpoint）
- CRIU 官方将 Podman 列为集成平台（https://criu.org/Podman）
- Podman 支持将 checkpoint 导出为可移植归档

**实施步骤：**

```bash
# 1. 安装 Podman 和 CRIU
apt install podman criu

# 2. 运行 ReDroid（命令兼容 Docker）
podman run -itd --rm --privileged \
    -v ~/data:/data \
    -p 5555:5555 \
    --name redroid \
    redroid/redroid:12.0.0_64only-latest

# 3. Checkpoint（需要 root）
sudo podman container checkpoint redroid \
    --export=/tmp/redroid-checkpoint.tar.gz

# 4. Restore
sudo podman container restore redroid \
    --import=/tmp/redroid-checkpoint.tar.gz
```

**优势：**
- API 兼容 Docker，迁移成本低
- Checkpoint 可导出为归档文件，支持跨主机恢复
- 命令行直接支持 `--tcp-established` 等 CRIU 选项

**风险：**
- ReDroid 的 `--privileged` 模式仍会引入复杂挂载
- Podman rootless 模式与 ReDroid 不兼容（Binder 需要 root）
- 底层仍调用 CRIU，挂载问题可能相似

**预计工时：1-2 周**

---

### 方案 C：Docker + 激进挂载配置

**可行性评级：5/10**

**原理：** 在现有 Docker 环境下，通过组合 CRIU 的所有挂载相关选项尝试绕过失败。

**依据：**
- CRIU v4.x 引入了 Mount-v2 算法（https://criu.org/Mount-v2），使用 `MOVE_MOUNT_SET_GROUP`（Linux 5.15+）解耦挂载创建和传播组
- 多个 CRIU 选项可以组合使用

**实施步骤：**

```bash
# 方法 1：通过 /etc/criu/runc.conf 传递选项给 Docker
cat > /etc/criu/runc.conf << 'EOF'
manage-cgroups full
enable-external-masters
enable-external-sharing
ghost-limit 10485760
link-remap
evasive-devices
EOF

# 然后使用 Docker 原生 checkpoint
docker checkpoint create redroid-experiment checkpoint1
docker start --checkpoint checkpoint1 redroid-experiment

# 方法 2：直接调用 CRIU（绕过 Docker）
# 获取容器 init 进程 PID
CONTAINER_PID=$(docker inspect -f '{{.State.Pid}}' redroid-experiment)

criu dump -t $CONTAINER_PID \
    --images-dir /tmp/criu-checkpoint \
    --manage-cgroups=full \
    --enable-external-masters \
    --enable-external-sharing \
    --external 'mnt[]:sm' \
    --ghost-limit 10485760 \
    --link-remap \
    --evasive-devices \
    --tcp-established \
    -v4

# 方法 3：结合 VFS 存储驱动消除 OverlayFS
# /etc/docker/daemon.json
{
    "storage-driver": "vfs"
}
# 注意：VFS 驱动每个容器完整复制，磁盘使用量增大 5-10 倍
```

**优势：**
- 不需要更换容器运行时
- 在现有环境上直接尝试

**风险：**
- 成功概率较低，没有已知成功案例
- `--skip-mnt` 可能导致恢复后容器功能不完整
- Mount-v2 需要 Linux 5.15+，当前内核 5.4.0 不满足
- VFS 存储驱动的磁盘开销不实际

**预计工时：2-3 周（大量试错）**

---

### 方案 D：CRIU Action Script + 设备重建

**可行性评级：4/10（仅解决设备节点问题，不解决挂载问题）**

**原理：** 使用 CRIU 的 action script 钩子，在 restore 过程中重建 Android 设备节点。

**依据：**
- CRIU action script 文档（https://criu.org/Action_scripts）
- 提供 `pre-dump`、`post-dump`、`pre-restore`、`setup-namespaces`、`pre-resume`、`post-resume` 等钩子

**实施步骤：**

```bash
# android-fixup.sh - CRIU action script
#!/bin/bash
case "$CRTOOLS_SCRIPT_ACTION" in
    post-setup-namespaces)
        # 重建 Android 设备节点
        mknod /dev/binder c 10 232
        mknod /dev/hwbinder c 10 233
        mknod /dev/vndbinder c 10 234
        mknod /dev/ashmem c 10 235
        chmod 666 /dev/binder /dev/hwbinder /dev/vndbinder /dev/ashmem
        ;;
    pre-resume)
        # 可选：重启 servicemanager
        # kill -9 $(pidof servicemanager)
        # servicemanager 会被 init 自动重启
        ;;
esac

# 使用方式
criu dump ... --action-script /path/to/android-fixup.sh
criu restore ... --action-script /path/to/android-fixup.sh
```

**优势：**
- 可以在 restore 后自动执行修复操作
- 适合与其他方案（A/B/C）组合使用

**局限：**
- 不解决挂载命名空间问题（仍需方案 A/B/C 之一）
- 重建设备节点不能恢复 Binder 句柄状态
- 这是辅助手段，不是独立方案

---

### 方案 E：自定义最小 Android 容器

**可行性评级：6/10**

**原理：** 构建挂载结构最简化的 Android rootfs，绕过 CRIU 的挂载复杂性限制。

**依据：**
- Anbox 项目使用 LXC + 扁平 rootfs，比 Docker OverlayFS 简单得多
- Android 可配置为 system-as-root 模式（https://source.android.com/docs/core/architecture/partitions/system-as-root）

**实施步骤：**

```bash
# 1. 导出 ReDroid 镜像为扁平 rootfs
docker create --name temp redroid/redroid:12.0.0_64only-latest
docker export temp | docker import - redroid-flat:latest
docker rm temp

# 2. 使用扁平镜像运行（消除 OverlayFS 层）
docker run -d --name redroid-flat --privileged \
    -p 5555:5555 \
    redroid-flat:latest \
    /init

# 3. 进一步简化：手动构建最小 rootfs
# - 只挂载 /proc、/sys、/dev
# - 禁用不必要的 cgroup 控制器
# - 使用 static 设备节点代替 devtmpfs
```

**优势：**
- 从根源减少挂载点数量
- 扁平 rootfs 消除 OverlayFS 问题

**风险：**
- `docker export/import` 会丢失容器元数据（CMD、ENV、VOLUME 等）
- 需要手动配置启动命令
- Android 系统对挂载有硬性依赖，过度精简可能导致启动失败
- 需要 AOSP 构建经验（如果需要深度定制）

**预计工时：2-4 周**

---

### 方案 F：绕过 CRIU（混合方案）

**可行性评级：7/10**

**原理：** 放弃进程级 checkpoint，改用文件系统快照 + 应用状态序列化的混合方案。

**实施步骤：**

```
阶段 1：文件系统快照（Docker commit，当前已有）
    └── 保存：磁盘状态、安装的 APK、数据文件

阶段 2：应用状态序列化
    └── 在 checkpoint 前：
        - 测试应用主动序列化 Binder 句柄信息到文件
        - 记录所有活跃的 Service 连接
        - 保存 ActivityManager 状态快照

阶段 3：恢复重建
    └── 在 restore 后：
        - 从序列化文件恢复应用状态
        - 重新建立 Binder 连接
        - 验证句柄有效性
```

**优势：**
- 完全避开 CRIU 的挂载问题
- 可以精确控制保存/恢复的粒度
- 与现有 Docker commit 工作流兼容

**风险：**
- 不保存进程内存状态
- 需要修改测试应用配合
- 不是真正的"透明"checkpoint/restore

**预计工时：1-2 周**

---

## 3. CRIU 关键选项参考

以下是所有与 Android 容器相关的 CRIU 选项汇总：

### 3.1 挂载相关

| 选项 | 用途 | 对 ReDroid 的作用 |
|------|------|-------------------|
| `--external 'mnt[]:sm'` | 自动检测外部 bind mount（含 shared/master） | 处理 `/proc`、`/sys` 等宿主机绑定挂载 |
| `--external mnt[/path]:name` | 声明特定挂载为外部资源 | 可用于 `/system`、`/vendor` |
| `--enable-external-masters` | 允许 master_id 指向容器外的挂载 | **必须**：cgroup slave 挂载 |
| `--enable-external-sharing` | 允许 shared_id 指向容器外的挂载 | **必须**：shared 传播 |
| `--enable-fs <type>` | 对未知文件系统使用 bind mount 恢复 | 可用 `--enable-fs all` |
| `--skip-mnt <path>` | 跳过指定挂载（危险） | 最后手段 |

### 3.2 CGroup 相关

| 选项 | 用途 | 对 ReDroid 的作用 |
|------|------|-------------------|
| `--manage-cgroups=full` | 完全保存/恢复所有 cgroup | 处理 Android 的 cgroup 层级 |
| `--manage-cgroups=ignore` | 忽略 cgroup | 已测试，仍失败 |
| `--cgroup-root [ctrl]:/path` | 指定 cgroup 恢复路径 | 路径变化时使用 |

### 3.3 文件系统相关

| 选项 | 用途 | 对 ReDroid 的作用 |
|------|------|-------------------|
| `--ghost-limit <bytes>` | 增大已删除文件的保存限制 | Java/JNI 库常删除 .so 文件 |
| `--link-remap` | 允许创建临时硬链接 | 处理被删除路径的文件 |
| `--evasive-devices` | 处理不可达的设备文件 | Binder/ashmem 设备 |

### 3.4 Docker 集成

| 配置 | 用途 |
|------|------|
| `/etc/criu/runc.conf` | 覆盖 Docker/runc 传递给 CRIU 的选项 |
| `docker checkpoint create --checkpoint-dir=<dir>` | 指定 checkpoint 存储目录 |
| `--security-opt seccomp=unconfined` | 禁用 seccomp 过滤器（CRIU 需要） |

---

## 4. CRIU 近期发展（2024-2026）

### 4.1 Mount-v2 算法

CRIU v4.x 引入的 Mount-v2 算法是重要改进：

- 使用 `MOVE_MOUNT_SET_GROUP`（Linux 5.15+）
- 解耦挂载创建和传播组的建立
- 解决了 "mount trap" 和跨命名空间共享问题
- **显著提高了复杂容器 checkpoint 的成功率**

**限制：** 需要 Linux 5.15+，当前实验环境为 5.4.0，**不可用**。

### 4.2 Kubernetes Checkpoint/Restore 工作组（2026）

- Kubelet Checkpoint API 在 v1.30 进入 Beta
- 支持 containerd 和 CRI-O
- 主要面向标准容器，不针对 Android 容器
- 参考：https://kubernetes.io/blog/2026/01/21/introducing-checkpoint-restore-wg/

### 4.3 CRIU 插件系统

经调研，CRIU 插件 **不能** 解决挂载命名空间问题：

- 插件 API 仅处理"外部资源"（外部 socket、文件、设备）
- 没有自定义文件系统 checkpoint 逻辑的回调
- 没有字符设备状态保存的回调（无法处理 `/dev/binder`）
- 没有已知的 Binder/ashmem 插件实现

---

## 5. 方案对比矩阵

| 方案 | OverlayFS | 挂载复杂性 | 磁盘开销 | 实施难度 | 可行性 | 工时 |
|------|-----------|-----------|---------|---------|--------|------|
| **A: LXC + CRIU** | ✅ 无 OverlayFS | ✅ 大幅简化 | 正常 | 低 | **8/10** | 1-2 周 |
| **B: Podman + CRIU** | ⚠️ 可能有 | ⚠️ 部分简化 | 正常 | 低 | **7/10** | 1-2 周 |
| **C: Docker + 激进配置** | ⚠️ 可用 VFS 消除 | ❌ 仍然复杂 | VFS: 5-10x | 中 | **5/10** | 2-3 周 |
| **D: Action Script** | N/A（辅助） | N/A（辅助） | 无 | 低 | **4/10** | 0.5 周 |
| **E: 最小容器** | ✅ 扁平 rootfs | ✅ 大幅减少 | 正常 | 高 | **6/10** | 2-4 周 |
| **F: 混合方案** | N/A（绕过） | N/A（绕过） | 无 | 中 | **7/10** | 1-2 周 |

---

## 6. 推荐执行计划

### 第一优先：方案 A（LXC + CRIU）

**理由：**
1. ReDroid 官方支持 LXC 部署，降低了集成风险
2. LXC 有成熟的 CRIU 集成，`lxc-checkpoint` 自动处理外部挂载
3. 消除 OverlayFS 和 Docker 带来的额外挂载复杂性
4. 社区有大量成功案例

**执行步骤：**

```
第 1 周：环境搭建
├── 安装 LXC + CRIU
├── 验证 binder_linux/ashmem_linux 模块加载
├── 从 OCI 镜像创建 ReDroid LXC 容器
├── 验证 ADB 连通和应用运行
└── 运行 BinderTestApp 确认功能正常

第 2 周：Checkpoint/Restore 实验
├── 执行 lxc-checkpoint 保存快照
├── 记录所有错误信息
├── 逐步添加 CRIU 选项解决错误
├── 如成功：运行 BinderTestApp 验证 Binder 句柄状态
└── 如失败：记录具体失败点，转方案 B
```

### 第二优先：方案 B（Podman + CRIU）作为备选

如果方案 A 遇到 LXC OCI 模板兼容性问题，切换到 Podman。

### 并行推进：方案 D（Action Script）

无论选择哪个主方案，都应准备 action script 用于设备节点重建。这是一个通用的辅助工具。

### 兜底方案：方案 F（混合方案）

如果 CRIU checkpoint 在所有容器运行时下都无法成功，退回到 Docker commit + 应用状态序列化的混合方案。

---

## 7. 重要限制说明

**即使 CRIU checkpoint 成功，Binder 句柄仍会失效。**

这是两个独立的问题：

| 问题层次 | 描述 | 本文档覆盖 |
|----------|------|-----------|
| **L1: 容器挂载** | CRIU 无法处理 Android 容器的复杂挂载结构 | ✅ 本文档 |
| **L2: Binder 内核状态** | 即使 checkpoint 成功，Binder 驱动的内核状态不会被保存 | ❌ PLAN.md Phase 1-3 |

本文档的目标是解决 L1，使 CRIU 能够成功完成 checkpoint/restore 操作。L2（Binder 句柄恢复）需要 PLAN.md 中描述的内核修改工作。

**解决 L1 是 L2 的前提条件 —— 如果容器都无法 checkpoint，谈 Binder 状态恢复毫无意义。**

---

## 8. 参考资料

### CRIU 官方文档
- CRIU 主页：https://criu.org/
- 外部绑定挂载：https://criu.org/External_bind_mounts
- CGroup 处理：https://criu.org/CGroups
- Docker 集成：https://criu.org/Docker
- Mount-v2 算法：https://criu.org/Mount-v2
- 插件 API：https://criu.org/Plugins
- Action Scripts：https://criu.org/Action_scripts
- 外部资源：https://criu.org/External_resources
- LXC 集成：https://criu.org/LXC

### GitHub Issues
- Ashmem checkpoint 问题：https://github.com/checkpoint-restore/criu/issues/582
- Docker 特权容器问题：https://github.com/checkpoint-restore/criu/issues/563
- 外部 master 挂载：https://github.com/checkpoint-restore/criu/issues/2875
- OverlayFS 只读属性：https://github.com/checkpoint-restore/criu/issues/2632

### 项目相关
- ReDroid LXC 部署：https://github.com/remote-android/redroid-doc/blob/master/deploy/lxc.md
- Podman Checkpoint：https://podman.io/docs/checkpoint
- CRIU 最新版本 (v4.2)：https://github.com/checkpoint-restore/criu/releases/tag/v4.2

### 学术文献
- IEEE CRIU 多案例经验报告：https://ieeexplore.ieee.org/document/10628207/
- Kubernetes C/R 工作组：https://kubernetes.io/blog/2026/01/21/introducing-checkpoint-restore-wg/

### 本项目文档
- 实验报告：`docs/binder句柄失效实验/experiment-report-2025-02-19.md`
- CRIU 替代方案：`docs/binder句柄失效实验/criu-alternatives.md`
- Binder C/R 完整计划：`PLAN.md`
