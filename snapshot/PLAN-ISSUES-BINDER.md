# Binder 方案问题与修正

## 一、结论

当前 Binder 方案方向正确，但还不能直接实现。阻碍点不是“想法错误”，而是“前提、结构完整性和恢复编排都还不够严谨”。

本文档只讨论 Binder 层的问题；CRIU 容器前置问题见 `PLAN-ISSUES-SOLUTION.md`。

## 二、致命问题

### 2.1 缺少可用的静默机制

原 draft 假设 dump/restore 可以在 Binder 正常运行时直接进行，这是不成立的。

如果没有 quiesce/freeze：

- rb-tree 遍历会与并发事务竞争
- `todo` / transaction / death 队列可能在 dump 期间变化
- 恢复出来的对象图不一致

结论：Binder dump 的前提不是“能读到结构体”，而是“先拿到稳定点”。

### 2.2 不能在内核里按服务名查 ServiceManager

原 draft 里“按服务名在内核里解析目标服务”的思路不可行。

原因：

- ServiceManager 的名称注册表在用户空间
- Binder 驱动只知道 context manager 节点，不维护服务名映射
- 因此内核里不存在可靠的 `find_service_node_by_name()` 语义

修正方向：

- 不在内核里做服务名解析
- 通过完整恢复相关进程状态或由更高层显式协调目标 node 身份

### 2.3 单进程视角不够

原 draft 主要按“单个进程恢复自己的 Binder 状态”来描述，但 Binder 的核心关系是跨进程的。

风险：

- server node 还没恢复，client ref 已尝试建立
- 同一 context 中多个进程分别恢复，顺序不可控
- handle 虽然恢复了，但实际 target node 不存在

修正方向：

- 以 Binder context 为单位恢复
- 引入跨进程恢复顺序和统一编排

## 三、重大遗漏

### 3.1 `binder_node` 字段不完整

如果只保存 `ptr/cookie/strong/weak` 一类基础字段，仍然不够。

至少还要覆盖：

- 影响引用行为的状态位
- 异步事务相关信息
- 影响权限或调度行为的控制位

否则 restore 后很容易出现引用计数漂移、错误释放或泄漏。

### 3.2 `binder_ref` 的 death 状态缺失

`linkToDeath/unlinkToDeath` 是 Android framework 的基本机制。

如果不保存或不重建 death 相关状态：

- app 会收不到死亡回调
- 旧死亡监听可能悬空
- framework 对服务活性判断会出现偏差

### 3.3 `binder_proc` 的线程池语义缺失

如果缺少线程池关键参数：

- Binder 线程可能不再按原预期被拉起
- 请求处理能力与恢复前不一致
- 一些“恢复后能调用但偶发卡死”的问题很难定位

### 3.4 `binder_alloc` 恢复被过度简化

“重新 mmap 一下就行”这个前提过于乐观。

更稳妥的做法是：

- 第一阶段不追求透明恢复 alloc 内部缓冲状态
- 把“alloc 为空或处于稳定状态”列为 dump 约束
- 先跑通主干路径，再决定要不要深入恢复 alloc 内部细节

## 四、修正后的 Binder 设计要求

### 4.1 明确前置条件

Binder dump 必须建立在以下条件上：

- 无在途事务
- 无待处理队列
- 无不可处理的 alloc 残留状态
- 同一 Binder context 的恢复对象范围已确定

### 4.2 明确恢复目标

恢复目标不是“能重新打开 Binder 设备”，而是：

- node 图恢复
- ref 图恢复
- handle 编号恢复
- thread/thread-pool 语义恢复
- death 语义恢复

### 4.3 明确恢复边界

Binder 层不负责：

- AMS/WMS 的逻辑恢复
- 设备资源恢复
- 任意系统服务状态的强一致回滚

它只负责把“Binder 调用通路”重新打通。

## 五、建议的修正后执行顺序

### Phase 1：补 quiesce 能力

先定义并验证：

- 什么叫稳定点
- dump 前需要检查哪些条件
- 哪些状态在第一阶段直接禁止进入 checkpoint

### Phase 2：补完整镜像结构

目标：

- 重新整理 `proc/node/ref/thread/death/meta` 的导出结构
- 去掉不成立的内核服务名查找假设

### Phase 3：实现 restore 原型

目标：

- 支持按原 handle 编号重建 ref
- 先恢复 server-side node，再恢复 client-side ref
- 验证单 Binder context 下的最小可运行路径

### Phase 4：接入 CRIU

目标：

- dump/restore 镜像落盘
- 跨进程恢复编排
- 真实 checkpoint/restore 流程联调

## 六、Binder 层的完成标准

至少要满足：

1. 恢复后 Binder 代理不再普遍失效
2. 关键 handle 编号保持一致
3. 多进程共享同一 Binder context 时恢复顺序稳定
4. death / thread-pool / node-ref 关系不再明显漂移

结论：当前 Binder 方案最大的价值是已经找到了正确方向；下一步不是继续堆实现细节，而是先把前提和恢复边界修正成可执行形式。
