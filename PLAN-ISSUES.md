# 计划问题与修正索引

## 一、文档树

```text
PLAN-ISSUES.md
├── PLAN-ISSUES-BINDER.md
└── PLAN-ISSUES-SOLUTION.md
```

这组文档只做两件事：

1. 识别当前方案为什么还不能直接实施
2. 给出“先修什么、后修什么”的执行顺序

## 二、总体判断

当前方向是对的，但还不具备直接实施条件。

- `PLAN-BINDER.md` 解决的是 Binder 内核态保存/恢复
- 但在这之前，`CRIU 能否先处理 Android 容器` 是硬前提
- 即使 Binder 做完，`AMS/WMS/窗口/回调/设备状态` 仍然需要单独恢复

所以这不是一条线性问题，而是三层 gate：

1. `容器级 gate`：CRIU 是否能 dump/restore Android 容器
2. `Binder 级 gate`：Binder 状态是否能一致恢复
3. `系统服务级 gate`：恢复后的 app 是否还能继续和外部系统协同工作

## 三、问题树

### 3.1 Phase 0 前置阻塞

这是最先处理的问题，详细分析见 `PLAN-ISSUES-SOLUTION.md`。

- 当前已知失败点首先是 mount namespace / cgroup / 外部挂载，不是 Binder
- 如果 CRIU 连容器都不能 checkpoint，后续 Binder 改造没有验证入口
- 因此 `Phase 0` 必须先拿到一个“可成功 C/R 的 Android 运行环境”

### 3.2 Binder 方案正确性问题

详细分析见 `PLAN-ISSUES-BINDER.md`。

当前 Binder draft 的主要问题有三类：

- 有些前提在当前内核/实现里并不存在
- 有些关键结构没有保存完全
- 跨进程恢复顺序和原子性要求还没有被设计完整

### 3.3 非 Binder 状态问题

Binder 不是终点。即使 handle 恢复，app 与 `system_server`、`SurfaceFlinger`、设备驱动之间的外部状态仍然会漂移。

这部分不在本组文档里展开，详见：

- `PLAN-OTHER-STATES.md`
- `PLAN-OTHER-STATES-DETAIL.md`

## 四、修正优先级

| 优先级 | 任务 | 目标 | 详细文档 |
|---|---|---|---|
| P0 | 解决 CRIU 容器 checkpoint 阻塞 | 获得可验证环境 | `PLAN-ISSUES-SOLUTION.md` |
| P1 | 修正 Binder draft 中的错误前提 | 让 Binder 设计变成可实施方案 | `PLAN-ISSUES-BINDER.md` |
| P2 | 明确恢复语义边界 | 决定是“无缝恢复”还是“允许部分重建” | `PLAN-OTHER-STATES.md` |
| P3 | 建立端到端验证矩阵 | 能判断每一阶段是否真正有效 | `PLAN-BINDER.md`、`PLAN-OTHER-STATES-DETAIL.md` |

## 五、建议的 gate

### Gate A：容器 checkpoint 基线

通过条件：

- 能 checkpoint Android 容器
- 能 restore 成功
- 进程仍存活
- 此时 Binder 失效是允许的

### Gate B：Binder 基线

通过条件：

- Binder fd 恢复后，关键系统服务调用不再直接 `DeadObjectException`
- 同一个 Binder context 内的 node/ref/handle 对应关系可重建
- 恢复顺序稳定且可重复

### Gate C：应用可用性基线

通过条件：

- AMS/WMS 路径不出现致命不一致
- UI、输入、通知、回调型服务可以重新绑定
- 关键业务路径能继续运行，而不是只“进程活着”

## 六、建议阅读顺序

1. `PLAN-ISSUES-SOLUTION.md`
2. `PLAN-ISSUES-BINDER.md`
3. `PLAN-BINDER.md`
4. `PLAN-OTHER-STATES.md`

结论很简单：先拿到可 checkpoint 的环境，再修 Binder，再处理系统服务状态；顺序不能反。
