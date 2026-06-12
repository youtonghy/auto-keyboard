import Foundation

@MainActor
final class RuleEngine {
    private let settings: SettingsStore
    private let sources: InputSourceManager
    private let memory: WindowStateStore

    /// 窗口当前生效的关键词匹配结果，用于只在“匹配状态变化”时切换，
    /// 避免标题频繁刷新时反复覆盖用户的手动选择
    private var lastKeywordMatch: [String: LangChoice] = [:]

    /// 用户手动切换后置位，焦点变化前抑制智能模式（选区变化触发）改回
    private var manualOverride = false

    init(settings: SettingsStore, sources: InputSourceManager, memory: WindowStateStore) {
        self.settings = settings
        self.sources = sources
        self.memory = memory
    }

    func noteManualSwitch() {
        manualOverride = true
    }

    func evaluate(focus: FocusTracker.Focus, trigger: FocusTracker.Trigger) async {
        guard settings.value.enabled,
              let en = settings.value.englishSourceID,
              let zh = settings.value.chineseSourceID,
              en != zh
        else { return }

        func source(_ lang: LangChoice) -> String {
            lang == .chinese ? zh : en
        }

        let isFocusEntry = trigger == .appActivated || trigger == .windowChanged || trigger == .elementChanged
        if isFocusEntry {
            manualOverride = false
        }

        let rule = settings.rule(for: focus.bundleID)
        var target: String?

        // 1. 强制模式 / 智能模式
        switch rule?.mode {
        case .forceEnglish:
            if isFocusEntry { target = en }
        case .forceChinese:
            if isFocusEntry { target = zh }
        case .smart:
            let smartTrigger = isFocusEntry || (trigger == .selectionChanged && !manualOverride)
            if smartTrigger, let detected = ContextDetector.detect(element: focus.element, window: focus.window, windowTitle: focus.windowTitle) {
                target = source(detected == .chinese ? .chinese : .english)
            }
        default:
            break
        }

        // 2. 标题关键词（沿触发：仅匹配状态变化时动作）
        if target == nil, let rule, !rule.keywordRules.isEmpty {
            let key = focus.key.raw
            let match = rule.keywordRules.first {
                !$0.keyword.isEmpty && focus.windowTitle.localizedCaseInsensitiveContains($0.keyword)
            }?.lang
            let previous = lastKeywordMatch[key]
            if match != previous {
                if lastKeywordMatch.count > 1000 { lastKeywordMatch.removeAll() }
                lastKeywordMatch[key] = match
                if let match {
                    target = source(match)
                } else if previous != nil, let def = rule.defaultLang {
                    // 关键词消失（如 claude/codex 退出）→ 回到应用默认
                    target = source(def)
                }
            }
        }

        // 3. 窗口记忆 / 应用默认（仅在进入窗口时恢复，避免与窗口内手动切换冲突）
        if target == nil, trigger == .appActivated || trigger == .windowChanged {
            target = memory.lookup(focus.key) ?? (rule?.defaultLang).map(source)
        }

        guard let target else { return }
        if target == sources.currentID {
            memory.record(focus.key, sourceID: target)
            return
        }
        if await sources.select(id: target) {
            memory.record(focus.key, sourceID: target)
        }
    }
}
