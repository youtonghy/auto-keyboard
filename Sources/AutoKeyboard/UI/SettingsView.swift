import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("通用", systemImage: "gearshape") }
            RulesTab()
                .tabItem { Label("应用规则", systemImage: "list.bullet.rectangle") }
            AboutTab()
                .tabItem { Label("说明", systemImage: "info.circle") }
        }
        .frame(width: 620, height: 480)
    }
}

// MARK: - 通用

private struct GeneralTab: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var sources: InputSourceManager
    @EnvironmentObject private var tracker: FocusTracker
    @EnvironmentObject private var smartLearning: SmartLearningStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?

    var body: some View {
        Form {
            Section("辅助功能权限") {
                HStack {
                    Image(systemName: coordinator.axTrusted ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(coordinator.axTrusted ? .green : .red)
                    Text(coordinator.axTrusted
                         ? "已授权，窗口跟踪与智能模式可用"
                         : "未授权 — 无法跟踪窗口和读取上下文")
                    Spacer()
                    if !coordinator.axTrusted {
                        Button("请求授权") { Permissions.requestAXPrompt() }
                        Button("打开系统设置") { Permissions.openAccessibilitySettings() }
                    }
                }
            }

            Section("输入源") {
                sourcePicker(title: "英文输入源", selection: Binding(
                    get: { settings.value.englishSourceID },
                    set: { settings.value.englishSourceID = $0 }
                ))
                sourcePicker(title: "中文输入源", selection: Binding(
                    get: { settings.value.chineseSourceID },
                    set: { settings.value.chineseSourceID = $0 }
                ))
                HStack {
                    Text("当前：\(sources.name(of: sources.currentID))")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("刷新列表") { sources.refreshAvailable() }
                }
            }

            Section("默认模式") {
                Picker("未列出的应用", selection: $settings.value.defaultMode) {
                    ForEach(AppMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text("单独添加的应用规则会覆盖此默认模式。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("当前应用识别状态") {
                if let focus = tracker.lastFocus {
                    let capability = ContextDetector.axCapability(
                        bundleID: focus.bundleID,
                        element: focus.element,
                        window: focus.window
                    )
                    LabeledContent("应用", value: focus.appName)
                    LabeledContent("AX 状态", value: capability.label)
                    Text("AX 黑盒应用只能使用窗口记忆或应用默认；不会进行组件级学习或上下文猜测。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("暂无前台应用信息")
                        .foregroundStyle(.secondary)
                }
            }

            Section("智能模式自学习") {
                Toggle("记住组件里的手动中英文纠正", isOn: $settings.value.smartLearningEnabled)
                HStack {
                    Text("已学习组件：\(smartLearning.count)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("清除已学习记录") {
                        smartLearning.clear()
                    }
                    .disabled(smartLearning.count == 0)
                }
                Text("仅在智能上下文模式中生效；记录组件指纹和中英文状态，不保存输入正文。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("启动") {
                Toggle("登录时启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                            launchError = nil
                        } catch {
                            launchError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let launchError {
                    Text(launchError).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func sourcePicker(title: String, selection: Binding<String?>) -> some View {
        Picker(title, selection: selection) {
            Text("未选择").tag(String?.none)
            ForEach(sources.available) { src in
                Text(src.localizedName).tag(Optional(src.id))
            }
        }
    }
}

// MARK: - 应用规则

private struct RulesTab: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach($settings.value.appRules) { $rule in
                    RuleRow(rule: $rule) {
                        settings.value.appRules.removeAll { $0.id == rule.id }
                    }
                }
            }
            Divider()
            HStack {
                addAppMenu
                Spacer()
                Text("未列出的应用：\(settings.value.defaultMode.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
        }
    }

    private var addAppMenu: some View {
        Menu("添加应用") {
            ForEach(candidateApps(), id: \.bundleID) { app in
                Button(app.name) {
                    settings.upsertRule(AppRule(bundleID: app.bundleID, displayName: app.name))
                }
            }
            Divider()
            Button("从应用程序文件夹选择…") { pickFromPanel() }
        }
        .frame(width: 140)
    }

    private func candidateApps() -> [(bundleID: String, name: String)] {
        let existing = Set(settings.value.appRules.map(\.bundleID))
        let selfID = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (String, String)? in
                guard let id = app.bundleIdentifier, id != selfID, !existing.contains(id) else { return nil }
                return (id, app.localizedName ?? id)
            }
            .sorted { $0.1.localizedCompare($1.1) == .orderedAscending }
    }

    private func pickFromPanel() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        let name = FileManager.default.displayName(atPath: url.path)
        settings.upsertRule(AppRule(bundleID: id, displayName: name))
    }
}

private struct RuleRow: View {
    @Binding var rule: AppRule
    let onDelete: () -> Void

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Picker("模式", selection: $rule.mode) {
                    ForEach(AppMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("应用默认语言", selection: $rule.defaultLang) {
                    Text("不设置").tag(LangChoice?.none)
                    ForEach(LangChoice.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                }

                Text("上下文关键词（匹配窗口标题、焦点元素或父级区域，如 claude / codex）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach($rule.keywordRules) { $kw in
                    HStack {
                        TextField("关键词", text: $kw.keyword)
                            .textFieldStyle(.roundedBorder)
                        Picker("", selection: $kw.lang) {
                            ForEach(LangChoice.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .frame(width: 90)
                        Button {
                            rule.keywordRules.removeAll { $0.id == kw.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    Button("添加关键词") { rule.keywordRules.append(KeywordRule()) }
                    Spacer()
                    Button("删除此应用规则", role: .destructive, action: onDelete)
                }
            }
            .padding(.vertical, 4)
        } label: {
            HStack {
                Text(rule.displayName)
                Text(rule.bundleID)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(rule.mode.label)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 说明

private struct AboutTab: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("AutoKeyboard").font(.title2.bold())
                Text("""
                工作方式：在「英文输入源」与「中文输入源」两个输入源之间自动切换（macOS 不提供控制输入法内部中英模式的接口，请在通用页选择实际使用的两个输入源）。

                规则优先级：强制中/英 > 上下文关键词 > 智能上下文/上下文分桶学习 > 窗口记忆 > 应用默认。

                • 窗口记忆：记录每个窗口最后使用的输入源，切回窗口时自动恢复。
                • 上下文关键词：窗口标题、当前焦点元素或父级区域命中关键词时切换（如终端运行 claude/codex，或编辑器侧栏聚焦到 AI 面板）；关键词消失后回到应用默认语言。
                • 智能上下文：仅在应用通过 AX 暴露真实输入组件、placeholder、文本或父级语义时启用。优先参考输入框 placeholder/标题/描述，再看输入框正文、焦点区域、窗口可见内容和标题。终端 shell 默认英文，codex/claude/opencode 等 Agent 活跃区域默认中文。若 Electron 应用只暴露空 AXGroup（如部分 Codex Desktop 状态），会降级为窗口记忆/应用默认，不再硬猜具体输入框。手动纠正会按“应用+上下文类型+组件+标签”分桶学习；AX 黑盒时只记录窗口记忆，不保存输入正文。

                提示：重新编译打包后（ad-hoc 签名变化）可能需要在系统设置中重新授权辅助功能。
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }
}
