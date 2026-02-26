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

## 当前实验进度

请参考 [PROGRESS.md](PROGRESS.md) 获取最新的实验进展和结果。


## 参考资料

- [ReDroid 官方文档](https://github.com/remote-android/redroid-doc)
- [Android Binder 机制](https://source.android.com/docs/core/architecture/hidl/binder-ipc)
- [CRIU - Checkpoint/Restore In Userspace](https://criu.org/)
