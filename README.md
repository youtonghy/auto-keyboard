# auto-keyboard

macOS 菜单栏应用：按窗口记忆中英文输入状态，并支持按应用规则与智能上下文自动切换输入法。

## 功能

- **窗口记忆**：记录每个窗口最后使用的输入源，切回该窗口时自动恢复（对所有应用默认生效）。
- **应用规则**：每个应用可设置模式 —— 窗口记忆 / 强制英文 / 强制中文 / 智能上下文，并可设置应用默认语言。
- **上下文关键词**：窗口标题、当前焦点元素或父级区域命中关键词时切换。预置终端 / iTerm2 规则：默认英文，标题或焦点区域含 `claude` / `codex` 时切中文；关键词消失（程序退出或焦点离开）后回到默认英文。
- **智能上下文**（需辅助功能权限）：读取光标附近约 600 字符判断语言 —— Word 中英文论文自动英文、中文论文自动中文。输入框为空时扫描窗口可见内容判断：微信聊天记录是中文则切中文，网页正文/页面语言自动跟随；最后回退到窗口标题。手动切换输入法后，在当前输入位置内不会被改回。

规则优先级：`强制中/英 > 智能上下文 > 上下文关键词 > 窗口记忆 > 应用默认`。

## 工作原理

macOS 不提供控制输入法内部中英模式（如按 Shift 切换的状态）的公开接口，本应用采用与 Input Source Pro 相同的方式：在两个**输入源**之间切换。请在设置中指定：

- 英文输入源：如 `ABC`
- 中文输入源：如 简体拼音 / 搜狗 / 鼠须管 等

窗口与上下文跟踪基于 Accessibility API（`AXObserver` 监听焦点窗口、焦点元素、标题与选区变化），语言判定使用汉字占比启发式 + `NLLanguageRecognizer`。上下文关键词会优先匹配窗口标题，再匹配当前焦点元素及其父级区域暴露的短文本元数据。

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
4. 在「应用规则」中为需要的应用添加规则；菜单栏中也可直接为当前应用快速设置模式。

## 已知限制

- 切换的是输入源整体，不是输入法内部的中英状态（系统限制）。
- 辅助功能权限与应用签名相关：重新编译、重新打包或更换签名身份后，可能需要在系统设置中删除旧的 AutoKeyboard 授权项，再重新授权。
- 智能模式依赖目标应用的辅助功能支持；部分应用（如某些 Electron 应用、Word 个别版本）暴露的文本信息有限时会回退到窗口标题判断。
- 浏览器输入框打字过程中不会实时重判语言，仅在聚焦输入框/移动光标时判定。
