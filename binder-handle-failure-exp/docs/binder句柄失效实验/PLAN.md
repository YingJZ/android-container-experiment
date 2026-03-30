# Binder 句柄失效实验计划

## 实验目标

复现 Android 容器快照恢复后 Binder 句柄失效问题。

## TODO List

### 阶段 1：环境准备

- [ ] 验证 binder 模块已加载 ✅ 已完成
- [ ] 验证容器内 /dev/binder 存在 ✅ 已完成
- [ ] 设置 ANDROID_HOME 环境变量（构建 App 需要）
- [ ] 验证 ADB 连接：`adb -s localhost:5555 shell getprop`

### 阶段 2：构建测试应用

- [ ] 构建 debug APK：
  ```bash
  cd /home/yingjiaze/android-container-experiment/test-app/BinderTestApp
  ./gradlew assembleDebug
  ```
- [ ] 验证 APK 生成：`ls app/build/outputs/apk/debug/app-debug.apk`

### 阶段 3：安装测试应用

- [ ] 安装 APK 到容器：
  ```bash
  cd /home/yingjiaze/android-container-experiment
  ./scripts/redroid-manage.sh install test-app/BinderTestApp/app/build/outputs/apk/debug/app-debug.apk
  ```
- [ ] 验证安装：`adb -s localhost:5555 shell pm list packages | grep bindertest`

### 阶段 4：运行实验

- [ ] 启动测试应用：
  ```bash
  adb -s localhost:5555 shell am start -n com.experiment.bindertest/.MainActivity
  ```
- [ ] 点击"开始周期测试"按钮，或通过 ADB 触发：
  ```bash
  adb -s localhost:5555 shell am broadcast \
      -a com.experiment.bindertest.TEST_BINDER \
      -n com.experiment.bindertest/.BinderTestReceiver
  ```
- [ ] 验证快照前 Binder 状态正常（观察 App 日志无错误）

### 阶段 5：创建快照

- [ ] 创建容器快照：
  ```bash
  ./scripts/checkpoint-restore.sh snapshot experiment1
  ```
- [ ] 验证快照创建：`docker images | grep redroid-experiment`

### 阶段 6：停止并恢复容器

- [ ] 停止容器：
  ```bash
  docker stop redroid-experiment
  ```
- [ ] 等待几秒：`sleep 5`
- [ ] 从快照恢复：
  ```bash
  ./scripts/checkpoint-restore.sh restore-snap experiment1
  ```

### 阶段 7：验证 Binder 失效

- [ ] 重新连接 ADB：
  ```bash
  adb connect localhost:5555
  ```
- [ ] 触发 Binder 测试：
  ```bash
  adb -s localhost:5555 shell am broadcast \
      -a com.experiment.bindertest.TEST_BINDER \
      -n com.experiment.bindertest/.BinderTestReceiver
  ```
- [ ] 查看日志，检查 DeadObjectException：
  ```bash
  adb -s localhost:5555 logcat -d | grep -E "(BinderTest|DeadObjectException)"
  ```

### 阶段 8：收集与分析结果

- [ ] 收集调试日志：
  ```bash
  ./scripts/collect-logs.sh all
  ```
- [ ] 分析结果：
  ```bash
  ./scripts/checkpoint-restore.sh analyze
  ```
- [ ] 记录实验结论

## 一键运行（可选）

```bash
./scripts/checkpoint-restore.sh run-experiment
```

## 预期结果

成功复现时，日志中应出现：
```
BinderTestReceiver: ✗✗✗ ActivityManager: DeadObjectException - BINDER 句柄失效!
```

## 实验结果记录

| 测试项 | 快照前 | 恢复后 |
|--------|--------|--------|
| ActivityManager | | |
| PackageManager | | |
| ServiceManager | | |
| ContentResolver | | |

**结论：** _待填写_
