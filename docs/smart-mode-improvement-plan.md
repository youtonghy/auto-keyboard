# 智能模式改进计划

> 调研日期：2026-07-05。基于 main 分支 `0b5bea1` 与 OCR 分支 `afbc5da` 的代码分析，以及 macOS 系统 API 调研。

## 一、问题现状与根因分析

### 问题 1：部分软件定位速度慢，出现"输一半被自动切换"

#### 根因 A：AX 调用无超时上限，单次评估 IPC 次数过多

每次 AX 属性读取都是一次跨进程 Mach 消息往返。当前代码从未调用
`AXUIElementSetMessagingTimeout`，目标应用主线程繁忙（Electron 应用常见）时，
单次属性读取会阻塞到系统默认超时（约 6 秒）。

同时一次评估的 IPC 次数被放大了约 2 倍：

- `RuleEngine.evaluate` 中 `axCapabilityForFocus`（RuleEngine.swift:115）和
  `ContextDetector.detectDecision`（RuleEngine.swift:118）**各自完整执行一遍**
  `textNearCursor` + `focusRegionContext`（13 层祖先 × ~10 个属性）+
  `collectText`（最多 300 节点）+ `collectWindowText`（最多 300 节点）。
  单次评估最坏可达 **~3000 次同步 IPC，且全部在主线程**。
- `noteManualSwitch`（RuleEngine.swift:70-76）在用户手动切换输入源时同样跑两遍完整遍历。

结论：判定结果计算耗时可达数百毫秒甚至秒级，等 `TISSelectInputSource` 落地时
用户已经开始打字——这就是"输一半被切换"的一类来源（**迟到的切换**）。

#### 根因 B：打字过程中触发重判

`FocusTracker` 订阅了 `kAXSelectedTextChangedNotification`（FocusTracker.swift:57），
每次击键都会移动光标并触发该通知（400ms 防抖后进入 `evaluate`）。README 声称
"打字/移动光标过程中不会重判"，但代码实际允许以下路径在打字中切换：

1. **关键词规则**：`keywordTrigger` 包含 `selectionChanged`（RuleEngine.swift:180）。
   用户在终端里输入包含 `claude` 的命令，输到一半命中关键词 → 立即切中文。
2. **终端上下文翻转**：`isContentChange` 时若 `contextKind` 变化会重置
   `manualOverride` 并重判（RuleEngine.swift:152-158）；终端属于
   `isStrongContext`，光标所在行内容变化（如出现/消失 prompt 符号、出现 agent
   关键词）会在打字过程中来回翻转 shell/agent 判定并切换输入源。
3. **拼音组字文本污染**：中文输入法组字期间，很多应用的 `AXValue` 里是拉丁
   字母（如 `nihao`），`classify(cursorText)` 会判成英文，在强上下文中触发切英文，
   直接打断组字。

#### 根因 C：切换落地前无新鲜度校验

`evaluate` 是 async 的（中间有防抖 sleep + `sources.select` 的 await），完成时
不校验"焦点元素是否还是评估时那个"、"用户是否正在打字"，直接执行切换。

### 问题 2：部分软件定位不精准

1. **Electron/Chromium 应用建树时机问题**：`AXManualAccessibility` 只在
   `attach(to:)` 时设置一次（FocusTracker.swift:118），而 Chromium 是检测到 AX
   客户端后**按需、延迟**构建渲染进程的 AX 树。首次查询常拿到空壳
   `AXWindow/AXGroup`，被判成 `blackBox`/弱文本后直接回退窗口记忆，
   即使几百毫秒后树已经可用也不会重试。
2. **终端类应用整屏一个 `AXTextArea`**：`AXValue` 是整个屏幕缓冲区，没有
   "输入框"概念，placeholder/title 等语义属性缺失。关键词匹配只能依赖窗口标题和
   正则猜 prompt，历史回滚区里的 `codex`/`claude` 字样容易误判（代码已有部分
   规避，但仍是启发式对启发式）。
3. **关键词/名单硬编码**：终端 bundle ID、agent 关键词、聊天语义词都是
   写死的名单（ContextDetector.swift:68-122），名单外的应用无法覆盖。
4. **窗口正文采样污染**：`collectWindowText` 虽然跳过菜单/工具栏，但仍会把
   本地化 UI 文案、聊天历史等混入语言判定，导致"界面是中文的英文写作场景"误判。
5. **指纹通用化冲突**：`SmartLearningKeyBuilder` v3 指纹 = bundle + context +
   role/subrole + 最近标签。无标签时按 role 通用化，同一应用内所有同 role
   输入框共享一条记录，互相覆盖（README 已承认此限制）。

### OCR 分支搁置原因（分支 `OCR`，5 个提交）

- 光标定位链路（`AXGeometry.caretScreenRect`）优先依赖
  `kAXBoundsForRangeParameterizedAttribute`，但**空选区（纯光标）时大量应用返回
  `kAXErrorNoValue`**（已知十余年的 radar rdar://14285519），于是频繁降级到
  hit-test 元素 / 鼠标位置 / 窗口 bounds，裁剪区域退化甚至接近整屏。
- 截图用的 `CGWindowListCreateImage` 在 macOS 14 起已废弃，且多显示器/Retina
  坐标换算容易出偏差。

## 二、macOS API 调研结论

| 方向 | 结论 | 适用性 |
| --- | --- | --- |
| `AXUIElementSetMessagingTimeout` | 可对单元素或全局设置 AX 调用超时（如 0.1–0.3s），挂起应用快速失败而非卡 6 秒；配合 `AXUIElementCopyMultipleAttributeValues` 批量取属性可成倍减少 IPC | **必做**，直接解决"慢" |
| `AXObserver` 事件驱动 | 项目已采用（per-app observer + NSWorkspace 激活通知），架构正确；注意 system-wide 元素不支持通知，现有做法即标准做法 | 保持 |
| 光标屏幕坐标 | `kAXSelectedTextRangeAttribute` + `kAXBoundsForRangeParameterizedAttribute`；空选区失败时用 `{location: caret-1, length: 1}` 探测前一字符，再降级到**焦点元素整体 bounds**（几乎所有应用都支持 `kAXPosition/kAXSize`，对 OCR 裁剪已足够）。可参考开源 CursorBounds（caret → 元素 bounds → 鼠标 三级降级） | **推荐**，解决 OCR 裁剪 |
| Electron `AXManualAccessibility` | Electron 25+ 才修复设置报错问题（旧版设置返回错误但可能实际生效，应忽略返回值）；建树有延迟，首查空树属正常，需**延迟重查**。备选 `AXEnhancedUserInterface` 有干扰窗口移动的副作用，优先前者 | **必做**，解决 Electron 定位 |
| `TISSelectInputSource` | 全局切换、对前台任意应用生效（现有用法正确）；但存在 CJKV 老 bug：切中文输入法时常"菜单栏图标变了、实际没切"，需要焦点变化才生效。成熟 workaround 是 macism 的"临时窗口抢焦点再还回"方案（macOS 26 上仍有效） | **建议移植** macism workaround |
| 系统"自动切换到文稿的输入法" | TSM 内部机制，无公开 API 可读取或挂钩 | 不可用 |
| Input Method Kit（自研输入法） | `IMKTextInput` 能拿到每个文本会话的宿主 bundle、光标周围文本、聚焦回调，**彻底**解决上下文感知，不依赖 AX；但等于自己做一个中英合一输入法（候选窗/组字/按键全自研），产品形态改变 | 长期可选，短期不推荐 |
| ScreenCaptureKit + Vision | `SCScreenshotManager`（macOS 14+）+ `SCContentFilter` 限定焦点窗口 + `sourceRect` 裁剪，替代已废弃的 `CGWindowListCreateImage`；`VNRecognizeTextRequest` 中文须放 `recognitionLanguages` 首位。**注意 macOS 15 Sequoia 起屏幕录制权限每 30 天强制重新授权弹窗**，对常驻工具体验伤害大 | 仅作**可选兜底**，不做主路径 |
| `NLLanguageRecognizer` | 建议加 `languageConstraints = [.simplifiedChinese, .traditionalChinese, .english]` 硬性限定候选，并用 `languageHypotheses` 取置信度、低于阈值不切换（现有代码未用这两点） | **推荐**改进现有 `classify` |
| CGEventTap 键盘监听 | 需 Input Monitoring 权限；只能"事后"发现打错语言（如英文模式下打出拼音模式的字母流），做纠错信号可行，做主判定不行 | 可选（远期） |
| macOS 26 (Tahoe) 新 API | 无面向第三方的焦点文本上下文/输入法自动切换新 API | 无捷径 |

## 三、改进计划

### P0：性能与"打断输入"修复（收益最大、改动最小）

1. **设置 AX 消息超时**
   - `FocusTracker.attach(to:)` 中对 app element 调用
     `AXUIElementSetMessagingTimeout(appEl, 0.25)`（具体值实测调整），
     必要时对遍历中的子元素继承设置。
   - 预期：最坏情况从 6s/调用 降到 0.25s/调用，挂起应用不再拖死评估。
2. **消除重复遍历，一次快照复用**
   - 新增 `FocusSnapshot`：一次性收集 cursorText / focusRegionContext /
     regionText / windowText，`axCapability` 与 `detectDecision` 共用同一份
     快照（两者的入参形式已经支持，只需在 `RuleEngine.evaluate` 与
     `noteManualSwitch` 层面改为先采集后判定）。
   - 顺带用 `AXUIElementCopyMultipleAttributeValues` 合并同一元素的多属性读取
     （`focusRegionNode` 一个元素读 10 个属性 → 1 次调用）。
   - 预期：单次评估 IPC 次数下降 50%+（去重）再叠加批量读取的收益。
3. **降低采样预算、提早退出**
   - `collectText` 在 `classify` 已能给出高置信结论时提前终止；
     `textCollectionNodeBudget`/`charBudget` 按容量分档（焦点区域小预算、
     窗口兜底更小预算）。
4. **打字保护（核心：不打断用户）**
   - 切换执行前检查
     `CGEventSourceSecondsSinceLastEventType(.combinedSessionState, .keyDown)`：
     距上次击键 < 阈值（如 0.5s）且触发源是 `titleChanged`/`selectionChanged`
     时**跳过切换**（焦点进入类触发不受限，保证 tab 切字段仍即时生效）。
     该 API 无需额外 TCC 权限。
   - `evaluate` 在 `sources.select` 前做**新鲜度校验**：重读
     `kAXFocusedUIElementAttribute`（一次廉价调用），与评估时的元素不一致则放弃。
5. **收紧 `selectionChanged` 触发面**
   - 关键词规则匹配不再响应 `selectionChanged`（保留 `titleChanged`，
     标题变化才代表前台进程/页面变化）；或至少同样套用打字保护。
   - 终端上下文在打字保护窗口内冻结当前判定，避免 prompt 符号出现/消失导致
     来回翻转。
6. **（可选，同期评估）移植 macism 的 CJKV 切换 workaround**
   - 现有 `select(id:)` 的重试循环（InputSource.swift:64-71）能发现"没切成功"
     但解决不了"图标变了实际没切"。若实测复现该 bug，则引入临时窗口方案。

### P1：定位精准度

1. **Electron 建树重试**：设置 `AXManualAccessibility` 后（忽略返回值），
   若首次快照判定为 `blackBox`/空树，延迟 300–500ms 重新快照一次再定级；
   `attach` 后收到第一个焦点事件时同样允许一次延迟重查。
2. **分层判定管线**（按信号质量排序，逐级降级，替代目前"关键词优先"的平铺逻辑）：
   1. role/subrole 硬规则：`AXSecureTextField`（密码）→ 强制英文；
      URL/搜索框 subrole 可配置默认；
   2. 字段已有内容语言（cursorText + 改进版 `classify`）——"延续用户已有语言"
      是最稳的信号；
   3. placeholder / title / label / `AXDOMIdentifier` 语义（对文本整体跑语言
      识别 + 少量关键词规则，而非纯 `contains`）；
   4. per-app / 终端 / Electron 特判（现有名单逻辑收敛到这一层，并允许用户在
      设置里扩充名单，替代硬编码）；
   5. 窗口正文 → 窗口标题 → 窗口记忆/应用默认。
3. **`classify` 增强**：`NLLanguageRecognizer` 加 `languageConstraints` 与
   `languageHypotheses` 置信度阈值（<0.6 返回 nil 不切换）；组字期拉丁字母流
   的识别（连续无空格小写字母且当前源为中文 → 视为拼音组字，不判英文）。
4. **终端专项**：只取 `AXValue` 尾部当前行判 prompt（已有），历史区关键词仅在
   "该关键词位于最后 N 行"时生效，进一步压缩误判面。

### P2：记忆系统改进

现状：`SmartLearningStore`（500 条，last-write-wins，单一粒度指纹）+
`WindowStateStore`（窗口 → 输入源）两套独立记忆。

1. **多粒度指纹 + 分层查找**
   - 同一焦点同时生成三档 key：
     `精确档`（role+subrole+label，即现 v3）→
     `组件档`（role+subrole，无 label）→
     `上下文档`（bundle+contextKind，即现 fallback key）。
   - 查找时从精确到粗依次命中；**学习时写精确档**，粗档由精确档投票聚合，
     解决"无标签输入框互相覆盖"的问题。
2. **置信度与投票替代 last-write-wins**
   - Entry 增加 `votes`（中/英各自计数）与 `updatedAt`；单次误操作不再立即
     污染记录，连续一致的纠正才提升置信度；读取时低置信不生效。
3. **负反馈学习（直接治"被打断"的体感）**
   - 自动切换后 N 秒内用户手动切回 → 记一条**反向票**：该指纹下抑制这次
     自动判定来源（如 `cursor-text`），多次反向后该组件降级为"只跟随手动/记忆"。
4. **被动强化**
   - 用户在某组件持续输入（焦点停留且未手动切换）达到阈值 → 对当前语言 +1 票，
     让正确的自动判定自我巩固，无需用户显式纠正。
5. **统一分层记忆模型**
   - 明确三层：组件记忆（SmartLearning）→ 窗口记忆（WindowState）→ 应用默认，
     查找顺序与写入职责在一处定义，消除 RuleEngine 里分散的优先级判断。
   - 迁移：指纹版本升到 `v4`，旧 `v3` 记录按现有机制自然淘汰（加载时过滤）。

### P3：OCR 兜底复活（低优先级，默认关闭的实验特性）

前提认知：Sequoia 起屏幕录制权限每 30 天弹窗重授权，OCR 只适合作为
弱 AX 应用的**惰性兜底**，且必须是用户显式开启的选项。

1. **裁剪定位改造**（解决搁置根因）：
   - 三级降级明确化：caret bounds（含 `caret-1` 探测）→ **焦点元素整体
     bounds**（`kAXPosition/kAXSize`，几乎所有应用可用，作为主力）→ 鼠标点。
   - 放弃"以光标为竖直中心"的假设，改为"元素 bounds 内 OCR，
     再按 caret 相对位置加权选行"；元素过大时才收缩到 caret/鼠标带状区。
2. **截图 API 迁移**：`CGWindowListCreateImage`（已废弃）→
   `SCScreenshotManager.captureImage` + `SCContentFilter`（限定焦点窗口）+
   `SCStreamConfiguration.sourceRect`，统一处理 Retina `contentScale`。
   或不裁图、用 `VNRecognizeTextRequest.regionOfInterest` 归一化区域。
3. **门控保持现有设计**：仅弱 AX + smart 触发 + 无手动接管 + 节流，
   OCR 结果只作为 `classify` 的输入之一，永不覆盖学习记录。

### 不采纳 / 远期观察

- **IMKit 自研输入法**：唯一"彻底解"，但等于换赛道做输入法本身，投入不匹配
  当前产品形态；作为长期选项保留。
- **CGEventTap 键盘监听纠错**：额外 Input Monitoring 权限 + 只能事后纠错，
  P0 的打字保护已用无权限的 `CGEventSource` 计时器达到主要目的，暂不引入。

## 四、实施顺序与验证

| 阶段 | 内容 | 验证方式 |
| --- | --- | --- |
| P0 | 超时/去重/打字保护/新鲜度校验 | 单测：RuleEngine 触发面（selectionChanged 不再切换的用例）；手测矩阵：VS Code、iTerm2、Terminal、微信、Safari、Claude Desktop，Console.app 按 `com.autokeyboard` 观察单次评估耗时日志（需补充耗时打点） |
| P1 | 判定管线分层、Electron 重试、classify 增强 | 现有 ContextDetectorTests 扩充分层用例；ax-cli 对目标应用实测属性可用性 |
| P2 | 记忆 v4：多粒度+投票+负反馈 | SmartLearningStore/KeyBuilder 单测（迁移、投票、反向票）；手测纠正→复用路径 |
| P3 | OCR 兜底 | 在 OCR 分支上重构后合并，保留 debug 截图产物核对裁剪区域 |

基线：main 分支 71 个单测全部通过（2026-07-05 实测）。每阶段合并前跑
`swift test` 全量 + 上述手测矩阵。

## 五、风险与未决事项

- AX 行为（caret bounds 空选区失败、`AXManualAccessibility` 生效版本、
  TIS CJKV bug）多来自社区结论而非官方文档，**落地前需在目标应用清单上逐一
  实测**，建议先做 P0 的耗时打点再决定预算参数。
- 打字保护阈值（0.5s）与 Electron 重查延迟（300–500ms）需实测调参：
  过大延迟切换体感、过小保护不住。
- `CGEventSourceSecondsSinceLastEventType` 在无辅助功能权限外的场景行为
  需确认（本应用已必然持有 AX 权限，风险低）。
- 指纹升级 v4 会使既有学习记录失效一次（用户需重新纠正），发布说明中需提示。
- README「已知限制」中"打字/移动光标过程中不会重判"与当前代码不符，
  P0 落地时一并修正文档。
