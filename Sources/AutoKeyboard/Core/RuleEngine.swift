import Foundation
import os

@MainActor
final class RuleEngine {
    private let settings: SettingsStore
    private let sources: InputSourceManaging
    private let memory: WindowStateStoring
    private let smartLearning: SmartLearningStoring
    private let smartKeyForFocus: (FocusTracker.Focus, ContextKind) -> SmartLearningKey?

    /// 窗口当前生效的关键词匹配结果，用于只在“匹配状态变化”时切换，
    /// 避免标题频繁刷新时反复覆盖用户的手动选择
    private var lastKeywordMatch: [String: LangChoice] = [:]

    /// 用户手动切换后置位，同一窗口/同一上下文内抑制智能模式改回。
    private var manualOverride = false
    private var currentSmartKey: SmartLearningKey?
    private var learnedCurrentFocusEntry = false
    private var lastWindowKey: String?
    private var currentContextKind: ContextKind = .unknown
    private var manualOverrideContextKind: ContextKind = .unknown
    private var manualOverrideWindowKey: String?

    /// 调试日志：在 Console.app 中按 subsystem `com.autokeyboard` 过滤、开启"显示调试信息"即可看到
    /// 每次焦点事件的指纹输入与判定结果，用于核对指纹是否稳定。
    private let logger = Logger(subsystem: "com.autokeyboard", category: "smart")

    init(
        settings: SettingsStore,
        sources: InputSourceManaging,
        memory: WindowStateStoring,
        smartLearning: SmartLearningStoring,
        smartKeyForFocus: @escaping (FocusTracker.Focus, ContextKind) -> SmartLearningKey? = {
            SmartLearningKeyBuilder.key(bundleID: $0.bundleID, element: $0.element, contextKind: $1)
        }
    ) {
        self.settings = settings
        self.sources = sources
        self.memory = memory
        self.smartLearning = smartLearning
        self.smartKeyForFocus = smartKeyForFocus
    }

    func noteManualSwitch(sourceID: String, focus: FocusTracker.Focus?) {
        guard settings.value.enabled,
              let focus,
              let lang = lang(for: sourceID)
        else {
            manualOverride = true
            return
        }

        let rule = settings.rule(for: focus.bundleID)
        let mode = rule?.mode ?? settings.value.defaultMode
        guard mode != .forceEnglish, mode != .forceChinese else {
            manualOverride = true
            return
        }

        let decision = ContextDetector.detectDecision(
            bundleID: focus.bundleID,
            element: focus.element,
            window: focus.window,
            windowTitle: focus.windowTitle
        )
        let capability = ContextDetector.axCapability(
            bundleID: focus.bundleID,
            element: focus.element,
            window: focus.window
        )
        let contextKind = decision?.kind ?? .unknown
        manualOverride = true
        manualOverrideContextKind = contextKind
        manualOverrideWindowKey = focus.key.raw

        memory.record(focus.key, sourceID: sourceID)

        guard mode == .smart,
              settings.value.smartLearningEnabled,
              capability != .blackBox,
              !learnedCurrentFocusEntry
        else { return }

        // 始终从当前 live focus 重算指纹，避免使用陈旧的 currentSmartKey：
        // 焦点事件可能被防抖取消、或用户切换输入源时焦点元素已与上次 evaluate 不同。
        let key = smartKeyForFocus(focus, contextKind)
        guard let key else { return }
        currentSmartKey = key
        smartLearning.record(key, lang: lang)
        learnedCurrentFocusEntry = true
        logger.debug("learned \(lang.label, privacy: .public) for \(SmartLearningKeyBuilder.trace(bundleID: focus.bundleID, element: focus.element, contextKind: contextKind), privacy: .public)")
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

        let windowKey = focus.key.raw
        let windowIdentityChanged = windowKey != lastWindowKey
        lastWindowKey = windowKey
        let capability = ContextDetector.axCapability(
            bundleID: focus.bundleID,
            element: focus.element,
            window: focus.window
        )
        let contextDecision = capability == .blackBox
            ? nil
            : ContextDetector.detectDecision(
                bundleID: focus.bundleID,
                element: focus.element,
                window: focus.window,
                windowTitle: focus.windowTitle
            )
        let contextKind = contextDecision?.kind ?? .unknown

        let isWindowEntry = trigger == .appActivated
            || trigger == .windowChanged
            || (trigger == .elementChanged && windowIdentityChanged)
        let isFocusEntry = isWindowEntry || trigger == .elementChanged
        let isContentChange = trigger == .titleChanged || trigger == .selectionChanged
        let isSmartTrigger = isFocusEntry || isContentChange
        if isWindowEntry {
            // 进入新窗口/应用：完全重置，恢复自动判定
            manualOverride = false
            manualOverrideWindowKey = nil
            manualOverrideContextKind = contextKind
            learnedCurrentFocusEntry = false
            currentContextKind = contextKind
            currentSmartKey = capability == .blackBox ? nil : smartKeyForFocus(focus, contextKind)
        } else if trigger == .elementChanged {
            if contextKind != currentContextKind || manualOverrideWindowKey != windowKey {
                manualOverride = false
                manualOverrideWindowKey = nil
                manualOverrideContextKind = contextKind
            }
            // 窗口内切换字段：新组件可被学习，但保留用户在本窗口内的手动选择。
            // 关键：不重置 manualOverride，避免 tab 到相邻字段就被自动检测盖掉用户刚选的语言。
            learnedCurrentFocusEntry = false
            currentContextKind = contextKind
            currentSmartKey = capability == .blackBox ? nil : smartKeyForFocus(focus, contextKind)
        } else if isContentChange, contextKind != currentContextKind {
            manualOverride = false
            manualOverrideWindowKey = nil
            manualOverrideContextKind = contextKind
            currentContextKind = contextKind
            currentSmartKey = capability == .blackBox ? nil : smartKeyForFocus(focus, contextKind)
        }

        let rule = settings.rule(for: focus.bundleID)
        let mode = rule?.mode ?? settings.value.defaultMode

        if isFocusEntry {
            logger.debug("eval trig=\(self.triggerLabel(trigger), privacy: .public) mode=\(mode.rawValue, privacy: .public) override=\(self.manualOverride, privacy: .public) ax=\(capability.rawValue, privacy: .public) context=\(contextKind.rawValue, privacy: .public) source=\(contextDecision?.source ?? "nil", privacy: .public) \(SmartLearningKeyBuilder.trace(bundleID: focus.bundleID, element: focus.element, contextKind: contextKind), privacy: .public)")
        }

        var target: String?

        // 1. 强制模式
        switch mode {
        case .forceEnglish:
            if isFocusEntry { target = en }
        case .forceChinese:
            if isFocusEntry { target = zh }
        default:
            break
        }

        // 2. 上下文关键词。显式规则是用户配置的强信号，不受 manualOverride 阻挡。
        let keywordTrigger = isFocusEntry || trigger == .titleChanged || trigger == .selectionChanged
        if target == nil, keywordTrigger, let rule, !rule.keywordRules.isEmpty {
            let key = focus.key.raw
            let haystack = ContextDetector.keywordHaystack(element: focus.element, windowTitle: focus.windowTitle)
            let match = KeywordMatcher.match(in: haystack, rules: rule.keywordRules)
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

        // 3. 智能模式：先用 context kind 分桶学习，再用上下文建议。
        switch mode {
        case .smart:
            if capability == .blackBox {
                break
            }
            // 智能判定在进入焦点时运行；对明确的上下文变化/内容变化也允许重判，
            // 这样 Codex 对话输入、终端 prompt、Agent 区域能随实际上下文切换。
            guard isSmartTrigger else { break }
            if target == nil,
               isFocusEntry,
               settings.value.smartLearningEnabled,
               let key = currentSmartKey,
               let learned = smartLearning.lookup(key) {
                // 已学值优先级最高：用户曾为该组件纠正过的语言直接恢复
                target = source(learned)
                manualOverrideContextKind = contextKind
                manualOverrideWindowKey = windowKey
            } else if target == nil,
                      !manualOverride,
                      (isFocusEntry || isStrongContext(contextKind)),
                      let detected = contextDecision?.lang {
                // 无已学值且用户未在本窗口手动接管：按上下文判定一次并"提交"为本窗口的生效选择
                target = source(detected == .chinese ? .chinese : .english)
                manualOverrideContextKind = contextKind
                manualOverrideWindowKey = windowKey
            }
            // 否则（用户已手动接管）保持当前输入源，不与用户争抢
        default:
            break
        }

        // 4. 记忆等非智能模式下也能识别终端；终端更适合按当前行/agent 状态实时判定，
        // 而不是记住一次性的窗口输入源。
        if target == nil,
           mode == .memory,
           isSmartTrigger,
           !manualOverride,
           let terminalLang = contextDecision?.lang,
           contextKind == .terminalShell || contextKind == .terminalAgent {
            target = source(terminalLang == .chinese ? .chinese : .english)
            manualOverrideContextKind = contextKind
            manualOverrideWindowKey = windowKey
        }

        // 5. 窗口记忆 / 应用默认（仅在进入窗口时恢复，避免与窗口内手动切换冲突）
        if target == nil, isWindowEntry {
            target = memory.lookup(focus.key) ?? (rule?.defaultLang).map(source)
        }

        guard let target else { return }
        if target == sources.currentID { return }
        _ = await sources.select(id: target)
    }

    private func lang(for sourceID: String) -> LangChoice? {
        if sourceID == settings.value.englishSourceID { return .english }
        if sourceID == settings.value.chineseSourceID { return .chinese }
        return nil
    }

    private func triggerLabel(_ trigger: FocusTracker.Trigger) -> String {
        switch trigger {
        case .appActivated: "app"
        case .windowChanged: "win"
        case .elementChanged: "elem"
        case .titleChanged: "title"
        case .selectionChanged: "sel"
        }
    }

    private func isStrongContext(_ kind: ContextKind) -> Bool {
        switch kind {
        case .assistantChatInput, .terminalShell, .terminalAgent:
            true
        case .normalTextInput, .unknown:
            false
        }
    }
}

enum KeywordMatcher {
    static func match(in haystack: String, rules: [KeywordRule]) -> LangChoice? {
        rules.first {
            !$0.keyword.isEmpty && haystack.localizedCaseInsensitiveContains($0.keyword)
        }?.lang
    }
}
