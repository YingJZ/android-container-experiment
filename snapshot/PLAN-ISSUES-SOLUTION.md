# Phase 0：CRIU 容器前置问题

> 本文档只讨论 `L1` 问题：先让 CRIU 成功处理 Android 容器。  
> Binder 句柄恢复属于 `L2` 问题，另见 `PLAN-BINDER.md` 和 `PLAN-ISSUES-BINDER.md`。

## 一、目标

在投入 Binder C/R 改造前，先拿到一个能稳定完成下面流程的环境：

1. checkpoint Android 容器
2. restore Android 容器
3. 容器进程继续存活
4. 允许 Binder 在这一阶段仍然失效

只有这个 gate 通过，Binder 工作才有现实验证入口。

## 二、已知事实

### 2.1 当前失败不在 Binder 层

已有实验表明：

- CRIU 能识别 Binder 类型 fd
- 打开 `/dev/binderfs/binder` 本身不会直接导致 dump 失败
- 实际失败首先出现在挂载命名空间和 cgroup 传播结构

典型错误形态是：

- `unreachable sharing`
- 外部 master/shared mount 无法闭合
- Android 容器挂载树过于复杂，超出当前 Docker + CRIU 组合的稳态能力

### 2.2 当前问题根源

ReDroid 在容器里通常具备以下特征：

- `--privileged`
- 复杂的 `/proc`、`/sys`、cgroup bind mount
- 共享/从属传播关系
- Docker OverlayFS 层叠
- binderfs / ashmem / 其他 Android 特有设备节点

结论：当前 Phase 0 的主要矛盾是“容器运行时 + 挂载树复杂度”，而不是 Binder 设备本身。

## 三、方案树

### 3.1 推荐优先级

| 方案 | 核心思路 | 可行性 | 适用角色 |
|---|---|---:|---|
| A | `LXC + CRIU` | 8/10 | 主推方案 |
| B | `Podman + CRIU` | 7/10 | 次优备选 |
| C | `Docker + 激进 CRIU 选项` | 5/10 | 保留试验项 |
| D | `Action Script + 设备重建` | 4/10 | 辅助手段，不是主方案 |
| E | `最小 Android 容器` | 6/10 | 中期备选 |
| F | `绕过 CRIU 的混合方案` | 7/10 | 兜底路线 |

### 3.2 方案 A：LXC + CRIU

推荐原因：

- LXC 与 CRIU 集成成熟
- ReDroid 官方本身支持 LXC 部署
- 相比 Docker，LXC 的挂载结构更可控
- 可以减少 OverlayFS 与 daemon 层带来的额外变量

适用目标：

- 最快拿到“Android 容器可 checkpoint/restore”的验证环境

主要风险：

- 仍需验证 ADB、Binder 设备和 ReDroid 启动参数是否兼容
- 即便容器恢复成功，Binder 句柄仍然会失效

### 3.3 方案 B：Podman + CRIU

适合作为第二优先：

- CLI 与 Docker 接近，迁移成本较低
- 官方对 checkpoint/restore 支持更直接
- 仍可能保留部分容器运行时复杂度

### 3.4 方案 C：Docker + 激进配置

保留价值：

- 不需要更换运行时
- 可以快速验证“是否只是配置没打对”

主要问题：

- 成功概率偏低
- 当前内核对 Mount-v2 一类改进特性支持不足
- 可能花大量时间在试错上，但没有稳定出口

### 3.5 方案 D：Action Script

定位必须明确：

- 它可以修设备节点、做 restore 后的小修补
- 但它不能解决 mount namespace 根问题
- 也不能恢复 Binder 内核态

所以它只能作为主方案的辅助层。

### 3.6 方案 E：最小 Android 容器

思路：

- 展平 rootfs
- 尽量减少 OverlayFS、cgroup 和外部 bind mount
- 构造更适合 CRIU 的 Android 运行环境

价值：

- 如果 A/B/C 都卡住，这是比“继续堆选项”更结构化的改法

代价：

- 需要更深的容器与 Android 启动链改造

### 3.7 方案 F：混合方案

如果 CRIU 路线迟迟过不了 Gate A，则保留兜底方案：

- 文件系统快照用已有 Docker commit 路线
- 应用状态改为显式序列化/重建
- 放弃“透明进程级恢复”

这个方案不等价于 CRIU C/R，但能继续推进 Binder/系统服务恢复研究。

## 四、推荐执行顺序

### 4.1 第一优先

先做 `LXC + CRIU`：

1. 复现 ReDroid 在 LXC 中的基本启动
2. 确认 ADB 连通
3. 运行测试 app
4. 尝试 checkpoint/restore
5. 记录所有挂载、cgroup、设备相关失败点

### 4.2 第二优先

若 LXC 路线被 OCI 模板或设备映射卡住，则切到 `Podman + CRIU`，目的是尽快排除“只是 Docker 组合不合适”的可能。

### 4.3 并行准备

无论主路线是谁，都可并行准备：

- restore 阶段的 action script
- 设备节点修复脚本
- 针对 binderfs/ashmem 的环境检查脚本

### 4.4 兜底触发条件

满足以下任一情况，就应考虑转向混合方案：

- A/B/C 连续验证后仍无法通过 Gate A
- 问题长期停留在 mount namespace，且看不到稳定突破口
- 研究重点转向“应用态恢复策略”，而不是“透明进程级恢复”

## 五、Gate A 验收标准

通过条件：

- checkpoint 命令执行成功
- restore 命令执行成功
- Android 容器主进程存活
- ADB 重新连通
- 测试 app 进程仍存在

允许暂时失败：

- Binder 句柄失效
- app 与系统服务的交互不一致
- 窗口、输入、通知等高层状态损坏

也就是说，Phase 0 的定义是“容器能恢复”，不是“应用已经可用”。

## 六、Phase 0 输出物

建议把 Phase 0 的交付物定义为以下四项：

1. 一套可重复运行的容器启动方式
2. 一套可重复运行的 checkpoint/restore 命令
3. 一份失败点清单和规避参数说明
4. 一份 Gate A 验证记录

## 七、与后续 Binder 工作的边界

这里再次强调两层问题不可混淆：

| 层次 | 问题 | 是否由本文处理 |
|---|---|---|
| `L1` | Android 容器能否被 CRIU 成功 checkpoint/restore | 是 |
| `L2` | Binder 内核态与 handle 是否还能正确恢复 | 否 |

结论：Phase 0 的任务是给后续 Binder 研究创造试验场，而不是直接解决 Binder。
