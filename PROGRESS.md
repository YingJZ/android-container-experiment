# 实验进度

## Phase 0：使 CRIU 支持 Android 容器 Checkpoint/Restore

**方案：** 方案 A — LXC + CRIU（详见 [PLAN-ISSUES-SOLUTION.md](PLAN-ISSUES-SOLUTION.md)）  
**日期：** 2025-02-26  
**状态：** Checkpoint 成功 ✅ / Restore 调试中 🔧

---

### 一、已完成工作

#### 1. 计划审查与方案调研 ✅

- 分析 `PLAN.md` 正确性，发现 1 个 P0 阻塞项（CRIU 无法 checkpoint Android 容器）、3 个致命错误、5 个重大缺漏
- 产出修正后的 5 阶段执行计划（Phase 0-4）
- 调研 6 种可行方案（A-F），写入 `PLAN-ISSUES-SOLUTION.md`（556 行）
- 推荐方案 A（LXC + CRIU），可行性 8/10

#### 2. LXC 容器环境搭建 ✅

- 安装 `lxc-utils` 和 `lxc-templates`（LXC 4.0.12）
- 从 ReDroid Docker 镜像导出 rootfs（`rootfs.tar`，1.5GB）
- 提取 rootfs 到本地 ext4（`/tmp/lxc-redroid-local/`），避开 NFS 限制
- 编写 LXC 配置文件（`/tmp/lxc-redroid-local-config`）
- 编写 pre-start hook（binderfs + cmdline 设置）和 mount hook（设备节点创建）
- **容器成功启动** — Android 12 完整引导，49 个 Binder 服务运行
- 修复容器网络 — 路由规则 watchdog 对抗 Android netd
- ADB 连接验证：`172.17.0.100:5555`

#### 3. Binder 基线测试 ✅

- 8 个系统服务通过 Binder IPC 测试，0 失败
- binderfs 设备节点健康（509:12-15）

#### 4. CRIU Checkpoint — 迭代调试（20 轮） ✅

从 v4 到 v20，逐步定位并修复了 **8 个根因问题**，最终实现 Android 12 完整容器的 CRIU checkpoint（此前被认为不可能）。

| 版本 | Exit | img 文件数 | 错误 | 修复 |
|------|------|-----------|------|------|
| v4-v7 | 1 | 0 | `collect_sockets()` 静默失败 | — |
| v8 | 1 | 27 | SCM_RIGHTS 控制消息 | 加载内核 diag 模块 |
| v9 | 1 | 31 | binderfs VMA 不支持 | kill/restart logd |
| v10 | 1 | 31 | fdinfo/-1（补丁错误） | VMA 补丁 v1 |
| v11 | 1 | 33 | 无法 dump binder 字符设备 FD | VMA 补丁 v2 |
| v12 | 1 | 41 | trace_marker 挂载查找失败 | binder FD 补丁 |
| v13 | 1 | 139 | 未知 clock 类型 9 (timerfd) | tracefs 补丁 |
| v14 | 1 | 353 | POKEDATA 失败（竞态，D 状态） | timerfd clock 补丁 |
| v15 | 1 | 365 | POKEDATA 失败（freeze D 状态） | --freeze-cgroup |
| v16 | 1 | 353 | jit-zygote-cache 共享映射 POKEDATA | 无 pre-freeze |
| v17 | 1 | 375 | POKEDATA（补丁了错误的代码路径） | find_executable_area 补丁 |
| v18 | 1 | 373 | 队列中的控制消息 | get_exec_start 补丁 |
| v19 | 1 | 382 | 控制消息（logd SIGSTOP） | — |
| **v20** | **0** | **538** | **成功** | **sk-queue.c 补丁** |

#### 5. CRIU 补丁清单（共 7 个）

所有补丁基于 CRIU v4.0 源码（`/tmp/criu-src/`），已编译安装到 `/usr/local/bin/criu`。

| # | 文件 | 修改内容 | 解决的问题 |
|---|------|---------|-----------|
| 1 | `criu/proc_parse.c` | binderfs 设备 VMA 视为匿名内存 | mmap 的 `/dev/binderfs/*` 无法 dump |
| 2 | `criu/files.c` | binderfs 设备 FD 视为普通文件 | binder 字符设备 FD 无法 dump |
| 3 | `criu/filesystems.c` | `tracefs_parse()` 返回 0 而非 1 | tracefs 挂载被跳过，导致 trace_marker 文件找不到挂载点 |
| 4 | `criu/include/timerfd.h` | 白名单添加 `CLOCK_BOOTTIME_ALARM`(9) | Android health HAL 使用的 timerfd clock 类型不被支持 |
| 5 | `compel/src/lib/infect.c` | `find_executable_area()` 跳过 `MAP_SHARED` VMA | 线程级注入选中 `jit-zygote-cache` 共享映射导致 POKEDATA EIO |
| 6 | `criu/parasite-syscall.c` | `get_exec_start()` 跳过 `MAP_SHARED` VMA | 进程级注入同样选中共享映射（与 #5 不同代码路径） |
| 7 | `criu/sk-queue.c` | 跳过非 SCM_RIGHTS 控制消息（warn 而非 abort） | logd 等 socket 队列中的 SCM_CREDENTIALS 导致 dump 中止 |

#### 6. CRIU Restore — 初步尝试 🔧

| 版本 | Exit | 错误 | 说明 |
|------|------|------|------|
| v1 | 1 | "excessive parameter" | `--ext-mount-map auto` 格式问题 |
| v2 | 1 | "excessive parameter" | 同上 |
| v3 | 1 | "No mapping for 3373:(null) mountpoint" | `--ext-mount-map auto` 生效，31 个自动检测的外部挂载成功处理，但子命名空间挂载 3373 失败 |
| v4 | 1 | "No mapping for 3373:(null) mountpoint" | 显式指定 tracefs 映射无效（ns_mountpoint 为 null） |
| v5 | 1 | "No mapping for 3373:(null) mountpoint (ext_key=debugtracing_ext)" | 添加 debug 日志后确认 ext_key 值 |

---

### 二、当前阻塞问题

#### Mount 3373 — 子命名空间 tracefs 挂载恢复失败

**现象：**
```
Error (criu/mount.c:3136): mnt: No mapping for 3373:(null) mountpoint (ext_key=debugtracing_ext)
```

**已诊断的信息：**

| 字段 | 值 |
|------|-----|
| mnt_id | 3373 |
| ext_key | `debugtracing_ext` |
| ns_mountpoint | `(null)` |
| source | `tracefs` |
| root | `/` |
| fstype | 19 |

**问题分析：**

1. CRIU checkpoint 捕获了 **3 个挂载命名空间**：
   - **ns 13**（pid 1 / 容器 init）— 主容器挂载，flags `0x280000`
   - **ns 15**（pid 318920）— 子挂载命名空间，可能来自 zygote 子进程
   - **ns 16**（pid 318982）— 另一个子挂载命名空间

2. Mount 3373 来自子命名空间之一，有 flags `0x300000`（不同于主容器的 `0x280000`）

3. 它的 `ext_key` 是 `debugtracing_ext`（一个 CRIU 在 dump 阶段生成的命名外部挂载标识），不是 `AUTODETECTED_MOUNT`，所以走入了 `ext_mount_lookup()` 路径

4. `ext_mount_lookup()` 在用户提供的 `--ext-mount-map` 映射中找不到 `debugtracing_ext` 键，返回 `NULL`

5. `ns_mountpoint` 为 `(null)` 因为这个挂载点在子命名空间中没有被正确解析

**代码路径**（`/tmp/criu-src/criu/mount.c` L3107-3140）：
```c
if (!strcmp(me->ext_key, AUTODETECTED_MOUNT)) {
    ext = mi->source;            // 自动检测的挂载 → 使用 source
} else if (!strcmp(me->ext_key, EXTERNAL_DEV_MOUNT)) {
    ext = EXTERNAL_DEV_MOUNT;    // 设备挂载
} else {
    ext = ext_mount_lookup(me->ext_key);  // ← 查找用户提供的映射
    if (!ext) {
        // ← Mount 3373 在这里失败
        pr_err("No mapping for %d:%s mountpoint (ext_key=%s)\n", ...);
        return -1;
    }
}
```

---

### 三、待完成工作 (TODO)

#### 高优先级

1. **修复 mount 3373 恢复失败**

   可选方案（按优先级排序）：
   
   - **a) 提供显式映射**：`--ext-mount-map debugtracing_ext:/sys/kernel/debug/tracing`
   - **b) 补丁 mount.c**：对 `debugtracing_ext` 等已知的外部挂载 key 进行自动解析
   - **c) 跳过子命名空间挂载**：如果 Android zygote 子进程创建的挂载命名空间不是恢复所必需的
   - **d) 重新 checkpoint**：在 checkpoint 前先清理子命名空间（kill 相关进程），减少捕获的命名空间数量

2. **继续迭代 restore 调试** — 修复 mount 3373 后预计还会遇到更多问题

3. **Restore 成功后验证容器状态** — 确认 Android 系统正常启动

#### 中优先级

4. **Binder 句柄有效性测试** — 运行 8 服务 IPC 测试，对比 checkpoint 前的基线数据

5. **结果写入文档** — 更新 `PLAN-ISSUES-SOLUTION.md`

#### 低优先级

6. **Phase 1-4**（依赖 Phase 0 完成）— 内核级 Binder C/R 支持（见 `PLAN.md`）

---

### 四、关键发现

1. **缺失的内核 diag 模块导致 CRIU 静默失败**：`af_packet_diag` 未加载 → `collect_sockets()` 得到 `-ENOENT` → 错误静默传播。修复：`sudo modprobe af_packet_diag netlink_diag raw_diag`

2. **Android logd 累积 SCM_RIGHTS 消息**：checkpoint 前必须 kill/restart logd

3. **Binder 有两个 checkpoint 挑战**：(a) mmap 的设备 VMA — 补丁为匿名内存，(b) 打开的设备 FD — 补丁为普通文件

4. **CRIU 迭代调试有效**：每次修复解锁下一阶段：0 → 27 → 31 → 33 → 41 → 139 → 353 → 375 → 538 img files

5. **容器和宿主的 binder 设备号不同**：容器 509:12-15 vs 宿主 509:4-7（binderfs 按挂载分配）

6. **CRIU 不支持 `CLOCK_BOOTTIME_ALARM` (9) timerfd**：Android health HAL 使用，需加入白名单

7. **寄生代码注入有两个独立代码路径**：`get_exec_start()`（进程级）和 `find_executable_area()`（线程级），两者都需要跳过共享可执行映射

8. **Android 12 完整容器的 CRIU checkpoint 是可行的**：通过 7 个补丁到 CRIU 4.0，产出 538 个镜像文件（174MB）。此前被认为不可行。

9. **CRIU 捕获多个挂载命名空间**：Android zygote 子进程可能创建自己的挂载命名空间，导致恢复时需要处理额外的挂载映射

---

### 五、环境与文件参考

#### 环境

| 项目 | 值 |
|------|-----|
| 内核 | 5.15.0-97-generic |
| CRIU | 4.0（已打 7 个补丁） |
| LXC | 4.0.12 |
| 宿主用户 | yingjiaze (uid 1090)，有 sudo |
| 约束 | **公用服务器，禁止重启或破坏性操作** |

#### 关键文件

| 路径 | 说明 |
|------|------|
| `/usr/local/bin/criu` | 已打补丁的 CRIU 二进制文件 |
| `/usr/local/bin/criu.orig` | 原始未修改的 CRIU 二进制文件 |
| `/tmp/criu-src/` | CRIU v4.0 源码（含全部 7 个补丁） |
| `/tmp/lxc-redroid-local/` | 容器 rootfs（本地 ext4，容器已销毁但 rootfs 完好） |
| `/tmp/lxc-redroid-local-config` | LXC 容器配置 |
| `/tmp/lxc-redroid-binderfs/` | binderfs 宿主挂载点（509:4-7） |
| `/tmp/lxc-redroid-checkpoint-v20/` | **成功的 checkpoint 数据**（540 文件，174MB） |
| `/tmp/lxc-redroid-cmdline` | 伪 `/proc/cmdline`（Android 启动参数） |

#### 需要预加载的内核模块

```bash
sudo modprobe af_packet_diag netlink_diag raw_diag
```

#### 容器启动流程（如需重新 checkpoint）

```bash
sudo bash /tmp/lxc-redroid-local/hooks/pre-start.sh
sudo lxc-start -n redroid-local -f /tmp/lxc-redroid-local-config
# 等待 ~30s
PID=$(sudo lxc-info -n redroid-local -p | awk '{print $2}')
sudo nsenter -t $PID -n -- ip rule add from all lookup main prio 100
adb connect 172.17.0.100:5555
```

#### Checkpoint 前清理

```bash
# Kill logd 减少 SCM_RIGHTS 消息：
LOGD_PID=$(sudo nsenter -t $PID -p -m -- pidof logd 2>/dev/null)
sudo nsenter -t $PID -p -m -- kill -9 $LOGD_PID
sleep 2
```

---

### 六、历史实验

#### Binder 句柄失效实验（2025-02-19） 

详细报告：[docs/binder句柄失效实验/experiment-report-2025-02-19.md](docs/binder%E5%8F%A5%E6%9F%84%E5%A4%B1%E6%95%88%E5%AE%9E%E9%AA%8C/experiment-report-2025-02-19.md)

- 采用 ReDroid 作为 Android 容器环境
- Docker Commit 快照方式能正常进行，但无法复现 Binder 句柄失效（因为 Docker Commit 只保存文件系统，进程重新启动后会建立新连接）
- CRIU checkpoint/restore 失败（Docker 复杂挂载结构导致），这是本次 Phase 0 工作的起因
