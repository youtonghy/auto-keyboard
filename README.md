# auto-keyboard

macOS 菜单栏应用：按窗口记忆中英文输入状态，并支持按应用规则与智能上下文自动切换输入法。

## 功能

- **窗口记忆**：记录每个窗口最后使用的输入源，切回该窗口时自动恢复（对所有应用默认生效）。
- **默认模式与应用规则**：未列出的应用可统一设置模式；单个应用也可覆盖为窗口记忆 / 强制英文 / 强制中文 / 智能上下文，并可设置应用默认语言。
- **上下文关键词**：窗口标题、当前焦点元素或父级区域命中关键词时切换。预置终端 / iTerm2 规则：默认英文，标题或焦点区域含 `claude` / `codex` 时切中文；关键词消失（程序退出或焦点离开）后回到默认英文。
- **智能上下文**（需辅助功能权限）：仅在目标应用通过 AX 暴露真实输入组件、placeholder、文本或父级语义时启用。按输入框 placeholder/标题/描述等语义优先判断，再看输入框正文、焦点区域、窗口可见内容和标题。终端 shell 默认英文，`codex` / `claude` / `opencode` 等 Agent 活跃区域默认中文；若 Electron 应用只暴露空 `AXGroup`，会降级为窗口记忆/应用默认，不再硬猜具体输入框。用户手动纠正会被自学习记住，指纹按「应用 + 上下文类型 + 组件 role + 标签」建立；AX 黑盒时只记录窗口记忆，不做组件级学习。

规则优先级：`强制中/英 > 上下文关键词 > 智能上下文/上下文分桶学习 > 窗口记忆 > 应用默认`。

## 工作原理

macOS 不提供控制输入法内部中英模式（如按 Shift 切换的状态）的公开接口，本应用采用与 Input Source Pro 相同的方式：在两个**输入源**之间切换。请在设置中指定：

- 英文输入源：如 `ABC`
- 中文输入源：如 简体拼音 / 搜狗 / 鼠须管 等

窗口与上下文跟踪基于 Accessibility API（`AXObserver` 监听焦点窗口、焦点元素、标题与选区变化），语言判定使用终端上下文启发式、汉字占比启发式 + `NLLanguageRecognizer`。上下文关键词会优先匹配窗口标题，再匹配当前焦点元素及其父级区域暴露的短文本元数据。智能自学习只保存组件短元数据摘要与中/英文状态，不保存输入正文、选中文本、光标附近文本或窗口正文。

## 构建

要求：macOS 14+，Xcode / Swift 6 工具链。

本应用需要辅助功能权限。macOS 的 TCC 权限会绑定到 `.app` bundle 与签名身份，因此请不要直接运行 SwiftPM 生成的可执行文件；先打包成 `.app`，完成签名后再启动并授权。

```bash
bash scripts/make-app.sh
open build/AutoKeyboard.app
```

`scripts/make-app.sh` 会构建 release 版本、生成 `build/AutoKeyboard.app`，并自动做 ad-hoc 签名：

```bash
codesign --force --sign - build/AutoKeyboard.app
```

如果你有自己的 Developer ID 或 Apple Development 证书，也可以在打包后手动重新签名，再启动：

```bash
codesign --force --deep --sign "Developer ID Application: Your Name (TEAMID)" build/AutoKeyboard.app
open build/AutoKeyboard.app
```

本机自用不要求 notarization；如果要分发给其他用户，建议使用 Developer ID 签名并 notarize。也可直接用 Xcode 打开 `Package.swift` 开发调试，但正式使用请按上面的方式打包签名后启动。

## 发布

仓库包含手动触发的 GitHub Actions 发布流程：进入 **Actions → Release → Run workflow**，填写版本号（如 `0.1.0`），workflow 会构建 `AutoKeyboard.app`、注入版本号、打包为 zip，并创建 `v版本号` 的 GitHub Release。

## 首次使用

1. 先按「构建」步骤打包并签名，然后启动 `build/AutoKeyboard.app`。
2. 在 **系统设置 → 隐私与安全性 → 辅助功能** 中授权 AutoKeyboard。
3. 点击菜单栏键盘图标 → 设置，确认英文/中文输入源选择正确（首次启动会自动猜测）。
4. 在「通用」中选择未列出应用的默认模式，并按需开启或清除「智能模式自学习」；在「应用规则」中为需要覆盖的应用添加规则；菜单栏中也可直接为当前应用快速设置模式。

## 已知限制

- 切换的是输入源整体，不是输入法内部的中英状态（系统限制）。
- 辅助功能权限与应用签名相关：重新编译、重新打包或更换签名身份后，可能需要在系统设置中删除旧的 AutoKeyboard 授权项，再重新授权。
- 智能模式依赖目标应用的辅助功能支持；部分 Electron 应用不是天然黑盒，但若当前窗口只暴露空 `AXWindow/AXGroup`，AutoKeyboard 无法定位具体输入组件，会降级为窗口记忆/应用默认，不再做上下文猜测。
- 智能自学习按「应用 + 上下文类型 + 组件 role + 标签」建指纹；同一应用里的对话输入、终端 shell、Agent 区域会分开学习。无任何标签时按 role 通用化，可能把同类但不相关的输入框归在一起。
- 智能判定在每个焦点做一次（切到新窗口才重判），打字/移动光标过程中不会重判。
