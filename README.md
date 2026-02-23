# Android 容器 Binder 句柄失效实验

本项目用于复现和研究"容器从快照恢复后，App 持有的 Binder 句柄失效"问题。

## 问题背景

当 Android 容器（如 ReDroid）被快照并恢复后，运行中的 App 持有的 Binder 句柄会失效，导致：
- Service 连接断开
- AIDL 调用失败
- 系统服务（如 ActivityManager、PackageManager）不可用

### Binder 句柄失效的原因

1. **Binder 驱动状态不持久化**：Binder 驱动维护的句柄表存储在内核内存中，快照恢复后内核状态重置
2. **引用计数丢失**：Binder 对象的强/弱引用计数在恢复后不一致
3. **线程池状态不匹配**：Binder 线程池状态与恢复后的实际状态不同步

## 项目结构

```
android-container-experiment/
├── README.md                    # 本文档
├── scripts/
│   ├── setup-env.sh            # 环境设置脚本
│   ├── redroid-manage.sh       # ReDroid 容器管理
│   ├── checkpoint-restore.sh   # 快照/恢复实验脚本
│   └── collect-logs.sh         # 日志收集脚本
├── test-app/
│   └── BinderTestApp/          # 测试 App 源码
└── docs/
    └── experiment-guide.md     # 实验指南
```

## 快速开始

### 1. 环境准备

```bash
# 设置环境（需要 root 权限）
sudo ./scripts/setup-env.sh
```

### 2. 启动 ReDroid 容器

```bash
./scripts/redroid-manage.sh start
```

### 3. 安装测试 App

```bash
./scripts/redroid-manage.sh install test-app/BinderTestApp/app/build/outputs/apk/debug/app-debug.apk
```

### 4. 运行快照/恢复实验

```bash
./scripts/checkpoint-restore.sh run-experiment
```

## 系统要求

- **操作系统**：Linux (Ubuntu 20.04+ 推荐)
- **内核版本**：5.4+ (需要支持 binder_linux 和 ashmem_linux 模块)
- **Docker**：20.10+
- **内存**：建议 8GB+
- **存储**：建议 20GB+ 可用空间

## 内核模块要求

ReDroid 需要以下内核模块：
- `binder_linux`：Android Binder IPC 驱动
- `ashmem_linux`：Android 共享内存（或使用 memfd 替代）

## 参考资料

- [ReDroid 官方文档](https://github.com/remote-android/redroid-doc)
- [Android Binder 机制](https://source.android.com/docs/core/architecture/hidl/binder-ipc)
- [CRIU - Checkpoint/Restore In Userspace](https://criu.org/)
