# 基于 Flux 设计的 CRIU Binder 快照/恢复方案

## 一、当前 CRIU 的限制

### 1.1 CRIU 对 Binder 的完全无知

默认 CRIU 将 Binder 设备（`/dev/binder`、`/dev/hwbinder`、`/dev/vndbinder`）视为普通文件描述符。它**无法**处理以下内容：

**内核态状态缺失**：

- **Binder 节点（binder_node）**：当进程作为服务端注册 Binder 服务时，内核会为其创建 `binder_node`，包含引用计数、异步事务队列等。CRIU 完全不感知这些结构[17]
- **Binder 引用（binder_ref）**：客户端持有的对服务端节点的引用，通过整数 handle 标识。CRIU 不保存 handle 到 node 的映射关系[7][17]
- **Binder 缓冲区（binder_buffer）**：用于事务数据传输的内核缓冲区，CRIU 不保存其状态[17]
- **Binder 线程（binder_thread）**：每个参与 Binder 通信的线程在内核中有对应的 `binder_thread` 结构，包含事务栈、待处理工作列表等

**用户态关联缺失**：

- 进程 mmap 的 Binder 缓冲区区域（通常 1MB）在恢复时无法正确重建
- `BINDER_SET_CONTEXT_MGR` 等 ioctl 命令的状态丢失
- 进程的 Binder 上下文（`binder_proc`）无法恢复

**具体表现**：

```
检查点时：
  App 进程 → fd=5 → /dev/binder → binder_proc{
      pid, nodes[], refs[], threads[], buffer_mapping
  }

CRIU 保存的：
  App 进程 → fd=5 → /dev/binder  ← 仅此而已，内核态全部丢失

恢复时：
  App 进程 → fd=5 → /dev/binder → 新的空 binder_proc{}
  → 应用尝试通过 handle 2 调用服务 → 内核找不到对应引用 → 失败
```

### 1.2 相关内核数据结构概览

```c
// 每个打开 /dev/binder 的进程对应一个
struct binder_proc {
    struct hlist_node proc_node;        // 全局进程链表
    struct rb_root threads;             // 该进程的 binder_thread 红黑树
    struct rb_root nodes;               // 该进程创建的 binder_node 红黑树
    struct rb_root refs_by_desc;        // 按 handle 排序的引用红黑树
    struct rb_root refs_by_node;        // 按 node 排序的引用红黑树
    struct list_head todo;              // 待处理工作队列
    struct binder_alloc alloc;          // mmap 缓冲区管理
    int pid;
    // ...
};

struct binder_node {
    struct rb_node rb_node;
    struct binder_proc *proc;           // 所属进程
    struct hlist_head refs;             // 指向该 node 的所有引用
    int internal_strong_refs;
    int local_weak_refs;
    int local_strong_refs;
    binder_uintptr_t ptr;              // 用户态 BBinder 指针
    binder_uintptr_t cookie;           // 用户态附加数据
    // ...
};

struct binder_ref {
    struct rb_node rb_node_desc;
    struct rb_node rb_node_node;
    struct binder_node *node;           // 指向的目标 node
    struct binder_proc *proc;           // 所属进程
    struct binder_ref_data data;        // 包含 desc (即 handle)
    // ...
};

struct binder_thread {
    struct rb_node rb_node;
    struct binder_proc *proc;
    int pid;                            // 线程 tid
    struct binder_transaction *transaction_stack;
    struct list_head todo;
    // ...
};
```

## 二、设计思路

### 2.1 整体架构

由于你的场景是**同设备快照恢复**（Redroid 容器内），相比 Flux 的跨设备迁移，有以下简化：

- ✅ 不需要处理设备异构性
- ✅ 系统服务（ServiceManager、各种系统服务）在恢复时仍在运行
- ⚠️ 但系统服务的内部状态可能已变化（其他应用的操作、时间推移等）
- ⚠️ Binder 内核状态需要完整重建

```
┌─────────────────────────────────────────────────────────┐
│                    设计架构总览                           │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  ┌──────────────┐     ┌──────────────┐                 │
│  │  CRIU 用户态  │────→│ 镜像文件      │                 │
│  │  (修改部分)   │←────│ (新增 binder  │                 │
│  │              │     │  镜像格式)    │                 │
│  └──────┬───────┘     └──────────────┘                 │
│         │                                               │
│         │ ioctl / 新增接口                               │
│         ▼                                               │
│  ┌──────────────┐                                      │
│  │ Binder 驱动   │                                      │
│  │ (修改部分)    │                                      │
│  │ 新增:         │                                      │
│  │ - dump ioctl  │                                      │
│  │ - restore ioctl│                                     │
│  └──────────────┘                                      │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

### 2.2 修改 CRIU 以支持 Binder 快照

#### A. 内核侧修改：新增 Binder dump/restore ioctl

**文件**：`drivers/android/binder.c`

需要新增两个 ioctl 命令：

```c
// 新增 ioctl 命令定义
#define BINDER_DUMP_STATE    _IOR('b', 20, struct binder_dump_state)
#define BINDER_RESTORE_STATE _IOW('b', 21, struct binder_dump_state)
```

**定义导出的数据结构**：

```c
// 用于用户态和内核态之间传递 Binder 状态
struct binder_frozen_node {
    uint64_t ptr;              // binder_node->ptr (用户态 BBinder 地址)
    uint64_t cookie;           // binder_node->cookie
    int32_t internal_strong_refs;
    int32_t local_weak_refs;
    int32_t local_strong_refs;
    uint32_t has_async_transaction;  // 是否有异步事务
};

struct binder_frozen_ref {
    uint32_t desc;             // handle 编号
    uint64_t node_ptr;         // 目标 node 的 ptr（用于匹配）
    uint64_t node_cookie;      // 目标 node 的 cookie
    int32_t strong;            // 强引用计数
    int32_t weak;              // 弱引用计数
    // 用于标识目标服务
    int32_t target_pid;        // 目标进程 pid（0 表示 ServiceManager）
    char service_name[256];    // 如果是注册服务，记录名称
};

struct binder_frozen_thread {
    int32_t pid;               // 线程 tid
    int32_t looper;            // looper 状态标志
    uint32_t looper_need_return;
};

struct binder_frozen_fd {
    uint32_t num_nodes;
    uint32_t num_refs;
    uint32_t num_threads;
    uint64_t mmap_addr;        // mmap 映射的用户态地址
    uint64_t mmap_size;        // mmap 映射的大小
    // 后面跟随变长数组:
    // struct binder_frozen_node nodes[num_nodes];
    // struct binder_frozen_ref refs[num_refs];
    // struct binder_frozen_thread threads[num_threads];
};
```

**实现 dump ioctl**：

```c
static long binder_ioctl_dump_state(struct binder_proc *proc,
                                     unsigned long arg)
{
    struct binder_frozen_fd header;
    struct binder_frozen_fd __user *ubuf = (void __user *)arg;
    struct rb_node *n;
    void __user *data_ptr;

    binder_inner_proc_lock(proc);

    // 1. 统计数量
    header.num_nodes = 0;
    header.num_refs = 0;
    header.num_threads = 0;
    header.mmap_addr = proc->alloc.buffer;
    header.mmap_size = proc->alloc.buffer_size;

    for (n = rb_first(&proc->nodes); n; n = rb_next(n))
        header.num_nodes++;
    for (n = rb_first(&proc->refs_by_desc); n; n = rb_next(n))
        header.num_refs++;
    for (n = rb_first(&proc->threads); n; n = rb_next(n))
        header.num_threads++;

    // 2. 拷贝 header
    if (copy_to_user(ubuf, &header, sizeof(header))) {
        binder_inner_proc_unlock(proc);
        return -EFAULT;
    }

    data_ptr = (void __user *)(ubuf + 1);

    // 3. 导出所有 nodes
    for (n = rb_first(&proc->nodes); n; n = rb_next(n)) {
        struct binder_node *node = rb_entry(n, struct binder_node, rb_node);
        struct binder_frozen_node fn = {
            .ptr = node->ptr,
            .cookie = node->cookie,
            .internal_strong_refs = node->internal_strong_refs,
            .local_weak_refs = node->local_weak_refs,
            .local_strong_refs = node->local_strong_refs,
            .has_async_transaction = !list_empty(&node->async_todo),
        };
        if (copy_to_user(data_ptr, &fn, sizeof(fn))) {
            binder_inner_proc_unlock(proc);
            return -EFAULT;
        }
        data_ptr += sizeof(fn);
    }

    // 4. 导出所有 refs
    for (n = rb_first(&proc->refs_by_desc); n; n = rb_next(n)) {
        struct binder_ref *ref = rb_entry(n, struct binder_ref,
                                          rb_node_desc);
        struct binder_frozen_ref fr = {
            .desc = ref->data.desc,
            .node_ptr = ref->node->ptr,
            .node_cookie = ref->node->cookie,
            .strong = ref->data.strong,
            .weak = ref->data.weak,
            .target_pid = ref->node->proc ? ref->node->proc->pid : 0,
        };
        // 尝试解析服务名称（通过 ServiceManager 的映射）
        resolve_service_name(ref, fr.service_name, sizeof(fr.service_name));

        if (copy_to_user(data_ptr, &fr, sizeof(fr))) {
            binder_inner_proc_unlock(proc);
            return -EFAULT;
        }
        data_ptr += sizeof(fr);
    }

    // 5. 导出所有 threads
    for (n = rb_first(&proc->threads); n; n = rb_next(n)) {
        struct binder_thread *thread = rb_entry(n, struct binder_thread,
                                                 rb_node);
        struct binder_frozen_thread ft = {
            .pid = thread->pid,
            .looper = thread->looper,
            .looper_need_return = thread->looper_need_return,
        };
        if (copy_to_user(data_ptr, &ft, sizeof(ft))) {
            binder_inner_proc_unlock(proc);
            return -EFAULT;
        }
        data_ptr += sizeof(ft);
    }

    binder_inner_proc_unlock(proc);
    return 0;
}
```

**实现 restore ioctl**：

```c
static long binder_ioctl_restore_state(struct binder_proc *proc,
                                        unsigned long arg)
{
    struct binder_frozen_fd header;
    struct binder_frozen_fd __user *ubuf = (void __user *)arg;
    void __user *data_ptr;
    int i;

    if (copy_from_user(&header, ubuf, sizeof(header)))
        return -EFAULT;

    binder_inner_proc_lock(proc);

    data_ptr = (void __user *)(ubuf + 1);

    // 1. 恢复 nodes
    for (i = 0; i < header.num_nodes; i++) {
        struct binder_frozen_node fn;
        if (copy_from_user(&fn, data_ptr, sizeof(fn)))
            goto err;
        data_ptr += sizeof(fn);

        // 在当前进程中创建/恢复 binder_node
        restore_binder_node(proc, &fn);
    }

    // 2. 恢复 refs（关键步骤）
    for (i = 0; i < header.num_refs; i++) {
        struct binder_frozen_ref fr;
        if (copy_from_user(&fr, data_ptr, sizeof(fr)))
            goto err;
        data_ptr += sizeof(fr);

        // 查找目标 node 并建立引用，使用指定的 desc (handle)
        restore_binder_ref(proc, &fr);
    }

    // 3. 恢复 threads
    for (i = 0; i < header.num_threads; i++) {
        struct binder_frozen_thread ft;
        if (copy_from_user(&ft, data_ptr, sizeof(ft)))
            goto err;
        data_ptr += sizeof(ft);

        restore_binder_thread(proc, &ft);
    }

    binder_inner_proc_unlock(proc);
    return 0;

err:
    binder_inner_proc_unlock(proc);
    return -EFAULT;
}
```

**恢复引用的核心函数**：

```c
static int restore_binder_ref(struct binder_proc *proc,
                               struct binder_frozen_ref *fr)
{
    struct binder_ref *ref;
    struct binder_node *target_node = NULL;
    struct binder_proc *target_proc;

    // 情况 1: 目标是 ServiceManager (handle 0 或已知服务)
    if (fr->service_name[0] != '\0') {
        // 通过 ServiceManager 查找当前的服务 node
        target_node = find_service_node_by_name(fr->service_name);
    }

    // 情况 2: 目标是同一进程内的 node (内部连接)
    if (!target_node && fr->target_pid == proc->pid) {
        target_node = find_node_in_proc(proc, fr->node_ptr, fr->node_cookie);
    }

    // 情况 3: 目标是其他进程的 node
    if (!target_node) {
        target_proc = find_proc_by_pid(fr->target_pid);
        if (target_proc) {
            target_node = find_node_in_proc(target_proc,
                                            fr->node_ptr, fr->node_cookie);
        }
    }

    if (!target_node)
        return -ENOENT;

    // 创建引用，强制使用指定的 desc (handle)
    ref = binder_get_ref_for_node_with_desc(proc, target_node, fr->desc);
    if (!ref)
        return -ENOMEM;

    // 恢复引用计数
    ref->data.strong = fr->strong;
    ref->data.weak = fr->weak;

    return 0;
}
```

#### B. 新增强制指定 handle 的内核函数

默认的 `binder_get_ref_for_node` 会自动分配递增的 handle 编号。恢复时必须使用原来的 handle：

```c
// 新增：允许指定 desc 的引用创建
static struct binder_ref *binder_get_ref_for_node_with_desc(
    struct binder_proc *proc,
    struct binder_node *node,
    uint32_t desired_desc)
{
    struct binder_ref *ref;
    struct binder_ref_data *ref_data;

    // 检查 desired_desc 是否已被占用
    ref = binder_get_ref_olocked(proc, desired_desc, false);
    if (ref) {
        if (ref->node == node)
            return ref;  // 已存在且指向同一 node
        return NULL;     // 冲突
    }

    ref = kzalloc(sizeof(*ref), GFP_KERNEL);
    if (!ref)
        return NULL;

    ref->data.desc = desired_desc;
    ref->node = node;
    ref->proc = proc;

    // 插入红黑树
    rb_insert_ref_desc(proc, ref);
    rb_insert_ref_node(proc, ref);

    // 更新 node 的引用列表
    hlist_add_head(&ref->node_entry, &node->refs);

    return ref;
}
```

#### C. CRIU 用户态修改

**文件结构**（在 CRIU 源码中新增）：

```
criu/
├── criu/
│   ├── binder.c              # 新增：Binder 快照/恢复逻辑
│   ├── binder.h              # 新增：头文件
│   ├── cr-dump.c             # 修改：集成 binder dump
│   ├── cr-restore.c          # 修改：集成 binder restore
│   └── files-reg.c           # 修改：识别 binder fd
├── images/
│   └── binder.proto          # 新增：protobuf 镜像格式
```

**定义 protobuf 镜像格式**（`images/binder.proto`）：

```protobuf
syntax = "proto2";

message binder_node_entry {
    required uint64 ptr = 1;
    required uint64 cookie = 2;
    required int32 internal_strong_refs = 3;
    required int32 local_weak_refs = 4;
    required int32 local_strong_refs = 5;
    required bool has_async_transaction = 6;
}

message binder_ref_entry {
    required uint32 desc = 1;           // handle
    required uint64 node_ptr = 2;
    required uint64 node_cookie = 3;
    required int32 strong = 4;
    required int32 weak = 5;
    required int32 target_pid = 6;
    optional string service_name = 7;   // 已注册的服务名
    required bool is_internal = 8;      // 是否为进程内部连接
    required bool is_system_service = 9;// 是否为系统服务
}

message binder_thread_entry {
    required int32 pid = 1;
    required int32 looper = 2;
    required bool looper_need_return = 3;
}

message binder_fd_entry {
    required uint32 fd = 1;             // 文件描述符编号
    required string dev_path = 2;       // /dev/binder 等
    required uint64 mmap_addr = 3;
    required uint64 mmap_size = 4;
    repeated binder_node_entry nodes = 5;
    repeated binder_ref_entry refs = 6;
    repeated binder_thread_entry threads = 7;
}

message binder_process_state {
    required uint32 pid = 1;
    repeated binder_fd_entry fds = 2;
}
```

**CRIU 用户态 dump 逻辑**（`criu/binder.c`）：

```c
#include "binder.h"
#include "imgset.h"
#include "protobuf.h"
#include "images/binder.pb-c.h"

// 检测 fd 是否为 binder 设备
bool is_binder_fd(int fd, pid_t pid)
{
    char link_path[PATH_MAX];
    char target[PATH_MAX];
    ssize_t len;

    snprintf(link_path, sizeof(link_path), "/proc/%d/fd/%d", pid, fd);
    len = readlink(link_path, target, sizeof(target) - 1);
    if (len < 0)
        return false;
    target[len] = '\0';

    return (strcmp(target, "/dev/binder") == 0 ||
            strcmp(target, "/dev/hwbinder") == 0 ||
            strcmp(target, "/dev/vndbinder") == 0);
}

// Dump 单个 binder fd 的状态
int dump_one_binder_fd(int pid, int fd, BinderFdEntry *entry)
{
    int target_fd;
    struct binder_frozen_fd *frozen;
    size_t total_size;

    // 1. 通过 /proc/pid/fd/N 打开目标进程的 binder fd
    //    或者通过 parasite code 在目标进程中执行 ioctl
    target_fd = open_proc_fd(pid, fd);
    if (target_fd < 0)
        return -1;

    // 2. 先查询大小
    struct binder_frozen_fd header;
    if (ioctl(target_fd, BINDER_DUMP_STATE, &header) < 0) {
        pr_perror("Failed to dump binder state for pid %d fd %d", pid, fd);
        close(target_fd);
        return -1;
    }

    // 3. 分配足够的缓冲区并再次调用获取完整数据
    total_size = sizeof(header)
        + header.num_nodes * sizeof(struct binder_frozen_node)
        + header.num_refs * sizeof(struct binder_frozen_ref)
        + header.num_threads * sizeof(struct binder_frozen_thread);

    frozen = malloc(total_size);
    if (!frozen) {
        close(target_fd);
        return -ENOMEM;
    }

    if (ioctl(target_fd, BINDER_DUMP_STATE, frozen) < 0) {
        pr_perror("Failed to dump binder state (full)");
        free(frozen);
        close(target_fd);
        return -1;
    }

    // 4. 填充 protobuf 结构
    entry->fd = fd;
    entry->dev_path = strdup(get_binder_dev_path(pid, fd));
    entry->mmap_addr = frozen->mmap_addr;
    entry->mmap_size = frozen->mmap_size;

    // 填充 nodes
    entry->n_nodes = frozen->num_nodes;
    entry->nodes = calloc(frozen->num_nodes, sizeof(BinderNodeEntry *));
    struct binder_frozen_node *fn_arr =
        (void *)(frozen + 1);
    for (int i = 0; i < frozen->num_nodes; i++) {
        entry->nodes[i] = calloc(1, sizeof(BinderNodeEntry));
        binder_node_entry__init(entry->nodes[i]);
        entry->nodes[i]->ptr = fn_arr[i].ptr;
        entry->nodes[i]->cookie = fn_arr[i].cookie;
        entry->nodes[i]->internal_strong_refs = fn_arr[i].internal_strong_refs;
        entry->nodes[i]->local_weak_refs = fn_arr[i].local_weak_refs;
        entry->nodes[i]->local_strong_refs = fn_arr[i].local_strong_refs;
        entry->nodes[i]->has_async_transaction = fn_arr[i].has_async_transaction;
    }

    // 填充 refs（类似逻辑）
    // 填充 threads（类似逻辑）
    // ...

    free(frozen);
    close(target_fd);
    return 0;
}

// 主 dump 入口
int dump_binder_state(int pid)
{
    BinderProcessState state = BINDER_PROCESS_STATE__INIT;
    DIR *fd_dir;
    struct dirent *de;
    char fd_dir_path[PATH_MAX];
    int ret = 0;

    state.pid = pid;

    snprintf(fd_dir_path, sizeof(fd_dir_path), "/proc/%d/fd", pid);
    fd_dir = opendir(fd_dir_path);
    if (!fd_dir)
        return -1;

    // 遍历所有 fd，找到 binder fd
    GArray *binder_fds = g_array_new(FALSE, TRUE, sizeof(BinderFdEntry *));

    while ((de = readdir(fd_dir)) != NULL) {
        int fd = atoi(de->d_name);
        if (is_binder_fd(fd, pid)) {
            BinderFdEntry *entry = calloc(1, sizeof(BinderFdEntry));
            binder_fd_entry__init(entry);
            if (dump_one_binder_fd(pid, fd, entry) < 0) {
                ret = -1;
                break;
            }
            g_array_append_val(binder_fds, entry);
        }
    }

    closedir(fd_dir);

    state.n_fds = binder_fds->len;
    state.fds = (BinderFdEntry **)binder_fds->data;

    // 写入镜像文件
    if (ret == 0)
        ret = pb_write_one(img_from_set(glob_imgset, CR_FD_BINDER),
                           &state, PB_BINDER);

    // 清理...
    return ret;
}
```

**CRIU 用户态 restore 逻辑**（`criu/binder.c` 续）：

```c
// 恢复单个 binder fd
int restore_one_binder_fd(int pid, BinderFdEntry *entry)
{
    int binder_fd;
    int ret = 0;

    // 1. 打开 binder 设备
    binder_fd = open(entry->dev_path, O_RDWR | O_CLOEXEC);
    if (binder_fd < 0) {
        pr_perror("Failed to open %s", entry->dev_path);
        return -1;
    }

    // 2. 将 fd 调整到原来的编号
    if (reopen_fd_as(entry->fd, binder_fd) < 0)
        return -1;
    binder_fd = entry->fd;

    // 3. 重新建立 mmap 映射
    void *mapped = mmap((void *)entry->mmap_addr,
                        entry->mmap_size,
                        PROT_READ,
                        MAP_PRIVATE | MAP_FIXED,
                        binder_fd, 0);
    if (mapped == MAP_FAILED) {
        pr_perror("Failed to mmap binder buffer at %#lx", entry->mmap_addr);
        return -1;
    }

    // 4. 构造 frozen state 并调用 restore ioctl
    size_t total_size = sizeof(struct binder_frozen_fd)
        + entry->n_nodes * sizeof(struct binder_frozen_node)
        + entry->n_refs * sizeof(struct binder_frozen_ref)
        + entry->n_threads * sizeof(struct binder_frozen_thread);

    struct binder_frozen_fd *frozen = malloc(total_size);
    frozen->num_nodes = entry->n_nodes;
    frozen->num_refs = entry->n_refs;
    frozen->num_threads = entry->n_threads;
    frozen->mmap_addr = entry->mmap_addr;
    frozen->mmap_size = entry->mmap_size;

    // 填充 nodes 数组
    struct binder_frozen_node *fn_arr = (void *)(frozen + 1);
    for (int i = 0; i < entry->n_nodes; i++) {
        fn_arr[i].ptr = entry->nodes[i]->ptr;
        fn_arr[i].cookie = entry->nodes[i]->cookie;
        fn_arr[i].internal_strong_refs = entry->nodes[i]->internal_strong_refs;
        fn_arr[i].local_weak_refs = entry->nodes[i]->local_weak_refs;
        fn_arr[i].local_strong_refs = entry->nodes[i]->local_strong_refs;
    }

    // 填充 refs 数组（类似）
    // 填充 threads 数组（类似）

    if (ioctl(binder_fd, BINDER_RESTORE_STATE, frozen) < 0) {
        pr_perror("Failed to restore binder state");
        ret = -1;
    }

    free(frozen);
    return ret;
}

// 主 restore 入口
int restore_binder_state(int pid)
{
    BinderProcessState *state;
    int ret;

    ret = pb_read_one(img_from_set(glob_imgset, CR_FD_BINDER),
                      &state, PB_BINDER);
    if (ret < 0)
        return ret;

    for (int i = 0; i < state->n_fds; i++) {
        ret = restore_one_binder_fd(pid, state->fds[i]);
        if (ret < 0)
            break;
    }

    binder_process_state__free_unpacked(state, NULL);
    return ret;
}
```

### 2.3 恢复时的关键步骤和注意事项

#### 恢复顺序至关重要

```
恢复流程（严格顺序）：

Step 1: 恢复进程基本状态（标准 CRIU）
  └─→ 内存映射、寄存器、信号处理器等

Step 2: 打开 Binder 设备并建立 mmap
  └─→ open(/dev/binder) + mmap
  └─→ 此时内核创建新的空 binder_proc

Step 3: 恢复 Binder nodes（进程作为服务端的部分）
  └─→ 必须先恢复 nodes，因为 refs 可能引用这些 nodes
  └─→ 对于进程内部的 Binder 连接尤其重要

Step 4: 恢复 Binder refs（进程作为客户端的部分）
  ├─→ 内部引用：指向 Step 3 恢复的 nodes
  ├─→ 系统服务引用：查找当前 ServiceManager 中的服务
  │   └─→ 关键：handle 编号必须与原来一致
  └─→ 其他外部引用：查找目标进程的 node

Step 5: 恢复 Binder threads
  └─→ 注册线程到 binder_proc 的线程池

Step 6: 恢复文件描述符映射
  └─→ 确保 binder fd 编号与原来一致

Step 7: 恢复进程执行
  └─→ 标准 CRIU 恢复执行流
```

#### 关键注意事项

**1. Handle 编号一致性**

这是最关键的要求。应用用户态代码中硬编码了 handle 编号来引用特定的系统服务[17][18]：

```
用户态代码中：
  sp<IBinder> binder = handle_to_binder(2);  // handle 2 = NotificationManager
  binder->transact(NOTIFY, data, &reply);

如果恢复后 handle 2 指向了不同的服务 → 灾难性错误
```

**2. ServiceManager 的特殊处理**

ServiceManager 始终是 handle 0（context manager）。恢复时需要确保[7]：

```c
// handle 0 始终指向 ServiceManager
// 这是 binder 驱动的硬编码行为
// 恢复时只需确保进程重新打开 binder 设备即可自动获得
```

**3. 系统服务 Node 可能已变化**

由于你的场景是等待一段时间后恢复，系统服务进程可能已重启，其 `binder_node` 的内核地址可能已改变：

```c
// 恢复引用时，不能直接使用原来的 node 内核地址
// 必须通过 ServiceManager 重新查找服务名 → 获取新的 node 引用

int restore_system_service_ref(struct binder_proc *proc,
                                struct binder_frozen_ref *fr)
{
    struct binder_node *new_node;

    // 通过 ServiceManager 查找服务
    // 这需要在内核中模拟一次 ServiceManager 查询
    // 或者在用户态先查询再传入
    new_node = lookup_service_node(fr->service_name);
    if (!new_node)
        return -ENOENT;

    // 使用原来的 handle 建立到新 node 的引用
    return create_ref_with_desc(proc, new_node, fr->desc);
}
```

**4. mmap 区域地址一致性**

Binder 的 mmap 区域地址被用户态 libbinder 缓存：

```c
// 恢复时必须映射到完全相同的虚拟地址
void *mapped = mmap((void *)original_mmap_addr,
                    original_mmap_size,
                    PROT_READ,
                    MAP_PRIVATE | MAP_FIXED,  // MAP_FIXED 确保地址一致
                    binder_fd, 0);
```

**5. 死亡通知（Death Notification）**

应用可能注册了对系统服务的死亡通知。恢复时需要重新注册：

```c
// 检查点时记录所有 death notification 注册
struct binder_frozen_death {
    uint32_t ref_desc;      // 监听的目标 handle
    uint64_t cookie;        // 回调标识
};

// 恢复时重新注册
int restore_death_notifications(struct binder_proc *proc,
                                 struct binder_frozen_death *deaths,
                                 int count)
{
    for (int i = 0; i < count; i++) {
        struct binder_ref *ref = binder_get_ref_olocked(proc,
                                                         deaths[i].ref_desc,
                                                         false);
        if (!ref) continue;
        binder_request_death_notification(proc, ref, deaths[i].cookie);
    }
    return 0;
}
```

### 2.4 可能遇到的挑战及解决方案

#### 挑战 1：进行中的 Binder 事务

**问题**：快照时可能有正在进行的 Binder 事务（`binder_transaction`），包括未完成的同步调用。

**解决方案**：

```c
// 方案 A：冻结进程后等待事务完成
int freeze_and_drain_binder(pid_t pid)
{
    // 1. 先冻结进程（SIGSTOP 或 cgroup freezer）
    kill(pid, SIGSTOP);

    // 2. 通过新增的 ioctl 检查是否有进行中的事务
    struct binder_transaction_status status;
    ioctl(binder_fd, BINDER_GET_TRANSACTION_STATUS, &status);

    if (status.pending_transactions > 0) {
        // 3. 短暂解冻让事务完成
        kill(pid, SIGCONT);
        usleep(10000);  // 10ms
        kill(pid, SIGSTOP);
        // 重复检查...
    }

    return 0;
}

// 方案 B（推荐）：使用 Binder freezer（Android 11+ 内核支持）
// BINDER_FREEZE ioctl 可以冻结进程的 binder 通信
int freeze_binder(int binder_fd, pid_t pid)
{
    struct binder_freeze_info info = {
        .pid = pid,
        .enable = 1,
        .timeout_ms = 1000,
    };
    return ioctl(binder_fd, BINDER_FREEZE, &info);
}
```

#### 挑战 2：Binder 缓冲区中的未消费数据

**问题**：`binder_alloc` 管理的缓冲区中可能有已分配但未被用户态消费的数据。

**解决方案**：

```c
// 在 dump 时额外保存 binder_alloc 的状态
struct binder_frozen_alloc {
    uint64_t buffer;           // 缓冲区起始地址
    uint64_t buffer_size;      // 缓冲区大小
    uint64_t free_async_space; // 剩余异步空间
    uint32_t num_buffers;      // 已分配的 buffer 数量
    // 每个已分配 buffer 的信息
    struct {
        uint64_t user_data;    // 用户态地址
        uint32_t data_size;
        uint32_t offsets_size;
        bool is_free;
        bool allow_user_free;
        bool async_transaction;
    } buffers[];
};

// 恢复策略：
// 对于同设备恢复，缓冲区中的待处理数据通常不需要恢复
// 因为对应的事务已经过期
// 只需恢复 alloc 的元数据使其处于一致状态
```

#### 挑战 3：Redroid 容器的 Binder 隔离

**问题**：Redroid 使用 binderfs 而非传统的 `/dev/binder`，每个容器有独立的 binder 设备。

**解决方案**：

```c
// 检测 Redroid 的 binder 设备路径
bool detect_binder_path(pid_t pid, char *path, size_t len)
{
    // Redroid 通常使用 binderfs
    // 路径可能是 /dev/binderfs/binder 或类似
    char proc_path[PATH_MAX];
    snprintf(proc_path, sizeof(proc_path), "/proc/%d/mountinfo", pid);

    FILE *f = fopen(proc_path, "r");
    // 解析 mountinfo 找到 binderfs 挂载点
    // ...

    // 或者直接从 /proc/pid/fd/N 的 readlink 获取
    return true;
}

// 在 CRIU 中注册 binderfs 设备的处理
// 修改 criu/files-reg.c 或新增 plugin
static int binder_file_dump(int lfd, u32 id, const struct fd_parms *p)
{
    if (is_binderfs_device(p->link.name)) {
        return dump_binder_fd_state(lfd, id, p);
    }
    return -ENOTSUP;
}
```

#### 挑战 4：恢复后系统服务中的应用状态丢失

**问题**：即使 Binder 连接恢复了，系统服务（如 NotificationManagerService）中关于该应用的状态可能已丢失（服务重启、超时清理等）。

**解决方案**：借鉴 Flux 的 Selective Record/Adaptive Replay 思想[10][11]，但简化版：

```
方案 A（简单）：依赖应用自身的容错机制
  - Android 应用通常能处理服务状态丢失
  - 恢复后通知应用 configuration change
  - 让应用自行重新注册监听器等

方案 B（完整）：实现简化版 Record/Replay
  - 在 Redroid 的 system_server 中拦截关键服务调用
  - 快照时保存调用日志
  - 恢复后重放调用日志
  - 这与 Flux 的设计一致
```

#### 挑战 5：Binder 引用计数一致性

**问题**：恢复时引用计数不正确会导致 node 过早释放或内存泄漏。

**解决方案**：

```c
// 恢复引用计数时需要同步更新 node 的计数器
int restore_ref_counts(struct binder_proc *proc,
                        struct binder_ref *ref,
                        int32_t target_strong,
                        int32_t target_weak)
{
    struct binder_node *node = ref->node;

    // 直接设置引用计数（绕过正常的 inc/dec 路径）
    binder_inner_proc_lock(node->proc);

    // 调整 node 的外部引用计数
    int strong_delta = target_strong - ref->data.strong;
    int weak_delta = target_weak - ref->data.weak;

    node->internal_strong_refs += strong_delta;
    node->local_weak_refs += weak_delta;

    ref->data.strong = target_strong;
    ref->data.weak = target_weak;

    binder_inner_proc_unlock(node->proc);
    return 0;
}
```

## 三、实现计划

### 阶段 1：内核侧 Binder 驱动修改（预计 2-3 周）

| 步骤 | 任务                     | 详情                                                         |
| ---- | ------------------------ | ------------------------------------------------------------ |
| 1.1  | 定义数据结构             | 在 `include/uapi/linux/android/binder.h` 中定义 frozen state 结构和新 ioctl 命令 |
| 1.2  | 实现 dump ioctl          | 在 `drivers/android/binder.c` 中实现 `BINDER_DUMP_STATE`，遍历 `binder_proc` 导出所有状态 |
| 1.3  | 实现 restore ioctl       | 实现 `BINDER_RESTORE_STATE`，包括 node 创建、ref 创建（指定 handle）、thread 注册 |
| 1.4  | 实现强制 handle 分配     | 新增 `binder_get_ref_for_node_with_desc` 函数                |
| 1.5  | 处理 ServiceManager 查询 | 在内核中实现通过服务名查找 node 的辅助函数，或提供用户态接口 |
| 1.6  | 单元测试                 | 编写内核模块测试 dump/restore 的正确性                       |

**关键文件修改清单**：

```
kernel/
├── include/uapi/linux/android/binder.h    # 新增 ioctl 定义和数据结构
├── drivers/android/binder.c               # 主要修改
├── drivers/android/binder_internal.h      # 可能需要导出内部结构
└── drivers/android/binder_alloc.c         # mmap 相关恢复支持
```

### 阶段 2：CRIU 用户态修改（预计 2-3 周）

| 步骤 | 任务                | 详情                                                         |
| ---- | ------------------- | ------------------------------------------------------------ |
| 2.1  | 定义 protobuf 格式  | 创建 `images/binder.proto`                                   |
| 2.2  | 实现 Binder fd 检测 | 在 `cr-dump.c` 中识别 binder/binderfs 设备 fd                |
| 2.3  | 实现 dump 路径      | 在进程冻结后、标准 dump 过程中调用 binder dump ioctl         |
| 2.4  | 实现 restore 路径   | 在进程恢复过程中，打开 binder 设备、mmap、调用 restore ioctl |
| 2.5  | 处理恢复顺序        | 确保 binder 恢复在文件描述符恢复之后、进程恢复执行之前       |
| 2.6  | 集成 binderfs 支持  | 处理 Redroid 使用的 binderfs 路径                            |

**关键文件修改清单**：

```
criu/
├── images/binder.proto                    # 新增
├── criu/include/binder.h                  # 新增
├── criu/binder.c                          # 新增：核心逻辑
├── criu/cr-dump.c                         # 修改：集成 binder dump
├── criu/cr-restore.c                      # 修改：集成 binder restore
├── criu/files.c                           # 修改：注册 binder fd 类型
├── criu/Makefile.crtools                  # 修改：添加编译目标
└── test/zdtm/static/binder_test.c        # 新增：测试用例
```

### 阶段 3：Redroid 集成与测试（预计 1-2 周）

| 步骤 | 任务             | 详情                                               |
| ---- | ---------------- | -------------------------------------------------- |
| 3.1  | 编译定制内核     | 将修改后的 binder 驱动编译进 Redroid 使用的内核    |
| 3.2  | 编译定制 CRIU    | 编译带 binder 支持的 CRIU                          |
| 3.3  | 基础测试         | 用简单的 Binder 客户端/服务端程序测试 dump/restore |
| 3.4  | 应用测试         | 在 Redroid 中测试实际 Android 应用的快照恢复       |
| 3.5  | 系统服务状态处理 | 测试恢复后应用与系统服务的交互是否正常             |
| 3.6  | 性能优化         | 优化 dump/restore 的性能                           |

### 阶段 4：处理边界情况（预计 1 周）

| 步骤 | 任务                         |
| ---- | ---------------------------- |
| 4.1  | 处理多进程应用               |
| 4.2  | 处理 hwbinder/vndbinder      |
| 4.3  | 处理 binder 事务超时和清理   |
| 4.4  | 处理恢复后的死亡通知重新注册 |
| 4.5  | 错误恢复和回滚机制           |

### 快速验证路径

如果你想快速验证可行性，可以先实现一个**最小可行版本**：

```
最小可行版本（约 1 周）：
1. 内核：仅实现 refs 的 dump/restore（最关键的部分）
2. CRIU：硬编码处理 /dev/binder
3. 测试：用一个简单的使用 Binder 的 Android 应用验证

然后逐步扩展到完整方案。
```

### 参考资源

- CRIU 源码：https://github.com/checkpoint-restore/criu
- Android Binder 驱动源码：`drivers/android/binder.c`
- Redroid 项目：https://github.com/remote-android/redroid-doc
- Flux 论文中 CRIA 的设计思路[16][17][18]
- CRIU 的 plugin 机制文档（可考虑以 plugin 形式实现而非修改核心代码）