# AX 负载保护实现说明

## 问题背景

部分应用（特别是复杂的 Web 页面、IDA Pro 等）的辅助功能树极为庞大，智能模式每次读取可能触发数百甚至数千次跨进程 IPC 调用，占用主线程数百毫秒甚至数秒。在用户打字过程中，每次击键都会触发 `selectionChanged` 事件并重新采样，导致系统明显卡顿，甚至看起来"冻住"或直接崩溃。

## 解决方案

实现了一套**智能模式负载保护（Smart Load Guard）**机制，包含两层防护：

### 第一层：运行时紧急熔断（Emergency Circuit Breaker）

在 AX 树遍历**过程中**实时检测开销，一旦触发紧急阈值立即中断：

- **紧急阈值**：`50 次 IPC 调用` 或 `0.1 秒主线程时间`
- **检测频率**：每处理 10 个节点检查一次 `meter.shouldAbort()`
- **触发后果**：立即 `break` 遍历，返回已收集的部分文本，**单次触发即永久暂停该应用**
- **目标**：防止畸形 AX 树（如 IDA Pro）拖垮主线程或导致崩溃

### 第二层：事后累积暂停（Post-Sampling Overload Tracking）

采样完成后评估总开销，连续超限则暂停：

- **过载阈值**：`700 次 IPC 调用` 或 `0.6 秒主线程时间`
- **暂停条件**：连续 3 次超限
- **暂停效果**：改用轻量采样模式（只读光标文本和祖先链，~20 次调用）
- **自动恢复**：10 分钟后放行一次完整采样重新评估

### 核心思路

1. **度量每次快照的真实开销**：记录 AX IPC 调用次数和主线程占用时间
2. **运行时立即中断**：在遍历中检测到超限立即刹车，避免崩溃
3. **按应用追踪超限次数**：连续 N 次超限后自动暂停该应用的智能模式
4. **暂停期间改用轻量采样**：只读光标文本和祖先链（读取次数有硬上限），跳过焦点区域与窗口正文的树遍历
5. **紧急中止永久暂停**：触发紧急熔断的应用直接永久暂停，不再试探（避免反复崩溃）

### 关键组件

#### 1. `AXLoadSample`（负载样本）
```swift
struct AXLoadSample {
    var axReads: Int              // AX IPC 调用次数
    var elapsed: TimeInterval     // 主线程占用时间（秒）
    var emergencyAborted: Bool    // 是否因紧急熔断而中止
}
```

记录单次快照的开销度量，判定是否超限：
- **紧急中止**：`emergencyAborted == true`（单次触发即永久暂停）
- **普通过载**：`axReads >= 700` 或 `elapsed >= 0.6s`（连续 3 次后暂停）

#### 2. `AXReadMeter`（读取计数器 + 熔断器）
```swift
final class AXReadMeter {
    private let emergencyReadLimit: Int = 50
    private let emergencyTimeLimit: TimeInterval = 0.1
    
    func shouldAbort() -> Bool  // 检查是否应立即中止遍历
}
```

在遍历循环中定期调用 `shouldAbort()`，超过紧急阈值立即返回 `true`。

#### 3. `AXSamplingMode`（采样模式）
```swift
enum AXSamplingMode {
    case full     // 完整采样：光标文本 + 祖先链 + 焦点区域 + 窗口文本
    case minimal  // 轻量采样：仅光标文本 + 祖先链
}
```

#### 4. `AXLoadGovernor`（负载调控器）
- 按 `bundleID` 追踪每个应用的超限次数（strikes）和暂停状态
- 区分**紧急中止**（永久暂停，`recheckAt = .distantFuture`）和**普通过载**（10 分钟后试探）
- 提供 `@Published var suspendedApps` 供 UI 显示

#### 5. `AXCapability.overloaded`（新状态）
```swift
enum AXCapability {
    case componentVisible  // AX 智能可用
    case textVisible       // AX 不完整，使用窗口记忆
    case blackBox          // AX 黑盒，无法定位具体输入组件
    case overloaded        // AX 读取开销过大，已暂停智能模式
}
```

被暂停的应用 `canUseSmartLanguageJudgment` 返回 `false`，智能判定与组件级学习都不再运行。

### 实现细节

#### 运行时熔断机制
在 `collectText` 遍历循环中每处理 10 个节点检查一次：
```swift
while index < queue.count, visited < profile.nodeBudget, collected.count < profile.charBudget {
    let (el, depth) = queue[index]
    index += 1
    visited += 1

    // 每处理 10 个节点检查一次紧急熔断
    if visited % 10 == 0, meter.shouldAbort() {
        break  // 立即中断遍历
    }
    // ... 继续处理节点
}
```

`meter.shouldAbort()` 检查：
- 已发出的 IPC 调用次数是否 >= 50
- 已占用的主线程时间是否 >= 0.1 秒

触发后立即 `break`，`FocusSnapshot.collect` 检测到 `meter.shouldAbort()` 并设置 `emergencyAborted = true`。

#### 度量 AX 调用次数
在 `ContextDetector` 中引入 `AXReadMeter` 追踪每个采样阶段的 IPC 次数：
- `textNearCursor`：~4 次调用（copyInt + copyRange + copyStringForRange + copyString）
- `focusAncestorChain`：13 层 × 1 次批量读取 + 13 次 parent 查询 = ~26 次
- `collectText`（焦点区域）：最多 160 节点 × (1 role + 0-1 value + 4 children 查询)
- `collectWindowText`：最多 120 节点 × 同上

**正常页面**：~20-50 次调用  
**复杂页面**：200-700 次调用  
**畸形页面（如 IDA Pro）**：可能上千次调用 → **触发紧急熔断在 50 次时中止**

#### 度量主线程时间
使用 `ContinuousClock` 在 `FocusSnapshot.collect` 和 `AXReadMeter` 初始化时测量：
```swift
let meter = AXReadMeter()  // 内部记录 startedAt = ContinuousClock.now
// ... 采样逻辑
let elapsed = AXLoadSample.elapsed(since: meter.startedAt)
```

#### RuleEngine 集成
```swift
// 1. 查询当前应用的采样模式
let mode = loadGovernor.samplingMode(for: focus.bundleID)

// 2. 按模式采样
let snapshot = snapshotForFocus(focus, mode)

// 3. 仅完整采样才记录负载
if mode == .full {
    loadGovernor.record(snapshot.load, bundleID: focus.bundleID, appName: focus.appName)
}

// 4. 紧急中止过的应用永久返回 .minimal，不再试探
let actualMode = loadGovernor.samplingMode(for: focus.bundleID)
let capability = actualMode == .minimal ? .overloaded : /* 正常判定 */
```

#### 负载记录逻辑
```swift
func record(_ sample: AXLoadSample, bundleID: String, appName: String) {
    // 紧急中止：单次触发立即永久暂停
    if sample.emergencyAborted {
        suspensions[bundleID] = Suspension(
            appName: appName,
            recheckAt: .distantFuture,  // 永不试探
            sample: sample,
            emergencyAborted: true
        )
        logger.warning("smart mode permanently suspended due to emergency abort")
        return
    }

    // 普通过载：连续 3 次后暂停，10 分钟后试探
    if sample.isOverloaded(limits) {
        strikes[bundleID] += 1
        if strikes[bundleID] >= 3 {
            suspensions[bundleID] = Suspension(
                appName: appName,
                recheckAt: now() + 600,  // 10 分钟后试探
                sample: sample,
                emergencyAborted: false
            )
        }
    } else {
        // 恢复正常
        strikes[bundleID] = nil
        suspensions.removeValue(forKey: bundleID)
    }
}
```

### 配置参数

在 `SmartLoadGuardSettings` 中定义（默认值）：
```swift
var maxAXReads: Int = 700             // 单次快照允许的 IPC 次数上限
var maxElapsedSeconds: TimeInterval = 0.6  // 单次快照允许占用主线程的秒数上限
var overloadStrikes: Int = 3          // 连续超限多少次后暂停智能模式
var recheckInterval: TimeInterval = 600    // 暂停后多久放行一次完整采样（秒）
var enabled: Bool = true              // 是否启用负载保护
```

### UI 集成

#### 菜单栏
- 显示当前应用的 AX 状态，包括 `.overloaded`
- 被暂停的应用显示"恢复「应用名」的智能模式"按钮

#### 设置 → 通用
- 新增"智能模式负载保护"区块
- 显示已暂停应用列表，每个应用可单独恢复
- 提供"全部恢复"按钮和"自动暂停开销过大的应用"开关

### 效果对比

#### 正常应用（如 Chrome、Safari 的普通页面）
- **无保护**：每次击键触发 200-300 IPC × ~1-2ms = 明显延迟
- **轻量采样**：每次击键 ~20 IPC × ~1ms = 流畅响应
- **策略**：连续 3 次超限后暂停，10 分钟后自动试探恢复

#### 复杂页面（如大型聊天窗口、复杂表格）
- **无保护**：每次击键触发 600-700 IPC × ~2-3ms = 卡顿明显
- **轻量采样**：每次击键 ~20 IPC × ~1ms = 流畅响应
- **策略**：连续 3 次超限后暂停，10 分钟后试探，若页面已简化则恢复

#### 极端应用（如 IDA Pro、畸形 AX 树）
- **无保护**：遍历数千节点 → 主线程卡死数秒 → **应用崩溃**
- **有紧急熔断**：遍历 50 次 IPC 或 0.1 秒后立即中断 → 单次触发即永久暂停
- **策略**：永不自动试探，避免反复崩溃；用户可手动恢复尝试

### 紧急熔断 vs 普通过载

| 特性 | 紧急熔断 | 普通过载 |
|------|---------|----------|
| **触发阈值** | 50 IPC 或 0.1s | 700 IPC 或 0.6s |
| **检测时机** | 遍历过程中实时检测 | 采样完成后评估 |
| **触发条件** | 单次超限 | 连续 3 次超限 |
| **暂停策略** | 永久暂停（.distantFuture） | 10 分钟后试探 |
| **恢复方式** | 仅手动恢复 | 自动试探 + 手动恢复 |
| **典型场景** | IDA Pro、畸形 AX 树 | 复杂 Web 页面、大型表格 |

### 效果

- **暂停前**：每次击键触发 700+ IPC × 0.25s 超时 = 明显卡顿
- **暂停后**：每次击键仅 ~20 IPC × 0.25s 超时 = 不再卡顿
- **智能判定降级**：该应用改用窗口记忆/应用默认，不影响关键词规则
- **自动恢复**：10 分钟后重新试探，若页面已简化则恢复智能模式

## 测试验证

所有 93 个单元测试通过，包括：
- `ContextDetectorTests`（44 个）：语言判定、终端检测、AX 能力分类
- `RuleEngineTests`（21 个）：智能学习、窗口记忆、模式切换
- `SettingsTests`（3 个）：配置解码兼容性
- `SmartLearningKeyBuilderTests`（14 个）：指纹生成稳定性
- `SmartLearningStoreTests`（9 个）：学习记录持久化
- `WindowKeyTests`（2 个）：窗口标识稳定性

## 向后兼容

- 旧版配置文件自动补充 `smartLoadGuard` 默认值
- 新增的 `AXCapability.overloaded` 在旧代码路径中不会出现
- `FocusSnapshot.load` 字段有默认值 `.zero`，不影响现有测试

## 文件变更清单

### 新增文件
- `Sources/AutoKeyboard/Core/AXLoadGovernor.swift`（166 行）

### 修改文件
- `Sources/AutoKeyboard/Model/Settings.swift`：新增 `SmartLoadGuardSettings`
- `Sources/AutoKeyboard/Core/ContextDetector.swift`：
  - 新增 `AXCapability.overloaded`
  - `FocusSnapshot` 增加 `load` 字段和 `mode` 参数
  - 所有遍历函数增加 `meter` 参数统计 IPC 次数
- `Sources/AutoKeyboard/Core/FocusTracker.swift`：
  - `copyStringLikes` 返回 `(values, reads)`
  - 暴露 `childrenAttributes` 常量
- `Sources/AutoKeyboard/Core/RuleEngine.swift`：
  - 接受 `loadGovernor` 依赖
  - `snapshotForFocus` 增加 `mode` 参数
  - `snapshotWithRetry` 记录负载并根据模式设置能力
  - `noteManualSwitch` 跳过超载应用的学习
- `Sources/AutoKeyboard/AppCoordinator.swift`：
  - 新增 `lazy var loadGovernor`
  - 新增 `axCapabilityForUI` 统一读取 UI 状态
- `Sources/AutoKeyboard/AutoKeyboardApp.swift`：注入 `loadGovernor` 到环境
- `Sources/AutoKeyboard/UI/MenuView.swift`：显示超载状态和恢复按钮
- `Sources/AutoKeyboard/UI/SettingsView.swift`：新增负载保护配置区块
- `Tests/AutoKeyboardTests/RuleEngineTests.swift`：
  - 测试 harness 传递 `loadGovernor`
  - `snapshotForFocus` 闭包增加 `mode` 参数
  - `snapshot(for:focus:)` 处理 `.overloaded` case
- `README.md`：说明负载保护机制

## 使用说明

用户无需手动配置，系统会自动检测并暂停超载应用。若需手动干预：

1. **查看状态**：菜单栏 → 当前应用显示"AX 读取开销过大，已暂停智能模式"
2. **立即恢复**：点击"恢复「应用名」的智能模式"按钮
3. **查看所有暂停应用**：设置 → 通用 → 智能模式负载保护
4. **识别紧急中止**：标注"已触发紧急熔断（永久暂停）"的应用建议谨慎恢复
5. **关闭保护**：取消勾选"自动暂停开销过大的应用"（不推荐）

**重要提示**：
- **紧急中止过的应用**（如 IDA Pro）恢复后若再次触发，会立即再次永久暂停
- 建议这类应用永久保持暂停状态，使用窗口记忆模式
- 关键词规则不受智能模式暂停影响，仍然正常工作

## 未来改进方向

1. **分页面追踪**：当前按应用暂停；未来可按窗口标题哈希细化，让同一应用的不同页面独立评估
2. **阈值动态调整**：根据用户设备性能（CPU 核心数、内存）自动调整阈值
3. **用户可见的性能指标**：在设置中显示各应用的平均 AX 耗时，帮助用户理解暂停原因
4. **持久化暂停列表**：当前会话内有效；可考虑跨会话持久化，避免每次重启都重新触发
