import ApplicationServices
import CoreGraphics
import Foundation
import os

@MainActor
final class RuleEngine {
    private struct TriggerScope {
        let isWindowEntry: Bool
        let isFocusEntry: Bool
        let isContentChange: Bool
        let isSmartTrigger: Bool
        let contentChangeProtectedByTyping: Bool
    }

    private let settings: SettingsStore
    private let sources: InputSourceManaging
    private let memory: WindowStateStoring
    private let smartLearning: SmartLearningStoring
    private let loadGovernor: AXLoadGovernor
    private let resolver: MemoryResolver
    private let smartKeysForFocus: (FocusTracker.Focus, ContextKind) -> SmartLearningKeyBuilder.Keys
    private let snapshotForFocus: (FocusTracker.Focus, AXSamplingMode) -> ContextDetector.FocusSnapshot
    private let axCapabilityForFocus: (FocusTracker.Focus, ContextDetector.FocusSnapshot, ContextDetectionConfig) -> AXCapability
    private let focusedElementForProcess: (pid_t) -> AXUIElement?
    private let secondsSinceLastKeyDown: () -> TimeInterval
    private let waitBeforeBlackBoxRetry: () async -> Void

    /// 窗口当前生效的关键词匹配结果，用于只在“匹配状态变化”时切换，
    /// 避免标题频繁刷新时反复覆盖用户的手动选择
    private var lastKeywordMatch: [String: LangChoice] = [:]

    /// 用户手动切换后置位，同一窗口/同一上下文内抑制智能模式改回。
    private var manualOverride = false
    private var currentSmartKeys = SmartLearningKeyBuilder.Keys()
    private var learnedCurrentFocusEntry = false
    private var lastWindowKey: String?
    private var currentContextKind: ContextKind = .unknown
    private var manualOverrideContextKind: ContextKind = .unknown
    private var manualOverrideWindowKey: String?
    private var lastAutomaticSwitch: (keys: SmartLearningKeyBuilder.Keys, lang: LangChoice, windowKey: String, at: Date)?
    private let typingProtectionInterval: TimeInterval = 0.5
    private let negativeFeedbackInterval: TimeInterval = 3.0

    /// 调试日志：在 Console.app 中按 subsystem `com.autokeyboard` 过滤、开启"显示调试信息"即可看到
    /// 每次焦点事件的指纹输入与判定结果，用于核对指纹是否稳定。
    private let logger = Logger(subsystem: "com.autokeyboard", category: "smart")

    init(
        settings: SettingsStore,
        sources: InputSourceManaging,
        memory: WindowStateStoring,
        smartLearning: SmartLearningStoring,
        loadGovernor: AXLoadGovernor? = nil,
        smartKeysForFocus: @escaping (FocusTracker.Focus, ContextKind) -> SmartLearningKeyBuilder.Keys = {
            SmartLearningKeyBuilder.keys(bundleID: $0.bundleID, element: $0.element, contextKind: $1)
        },
        snapshotForFocus: @escaping (FocusTracker.Focus, AXSamplingMode) -> ContextDetector.FocusSnapshot = { focus, mode in
            ContextDetector.FocusSnapshot.collect(element: focus.element, window: focus.window, mode: mode)
        },
        axCapabilityForFocus: @escaping (FocusTracker.Focus, ContextDetector.FocusSnapshot, ContextDetectionConfig) -> AXCapability = {
            $1.axCapability(bundleID: $0.bundleID, config: $2)
        },
        focusedElementForProcess: @escaping (pid_t) -> AXUIElement? = { pid in
            let app = AXUIElementCreateApplication(pid)
            AX.setMessagingTimeout(app)
            return AX.copyElement(app, kAXFocusedUIElementAttribute)
        },
        secondsSinceLastKeyDown: @escaping () -> TimeInterval = {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        },
        waitBeforeBlackBoxRetry: (() async -> Void)? = nil
    ) {
        self.waitBeforeBlackBoxRetry = waitBeforeBlackBoxRetry ?? {
            try? await Task.sleep(for: .milliseconds(350))
        }
        self.settings = settings
        self.sources = sources
        self.memory = memory
        self.smartLearning = smartLearning
        self.loadGovernor = loadGovernor ?? AXLoadGovernor(settings: settings)
        self.resolver = MemoryResolver(windowMemory: memory, smartLearning: smartLearning)
        self.smartKeysForFocus = smartKeysForFocus
        self.snapshotForFocus = snapshotForFocus
        self.axCapabilityForFocus = axCapabilityForFocus
        self.focusedElementForProcess = focusedElementForProcess
        self.secondsSinceLastKeyDown = secondsSinceLastKeyDown
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

        let samplingMode = loadGovernor.samplingMode(for: focus.bundleID)
        let snapshot = snapshotForFocus(focus, samplingMode)
        let capability = samplingMode == .minimal
            ? AXCapability.overloaded
            : axCapabilityForFocus(
                focus,
                snapshot,
                ContextDetectionConfig(settings: settings.value.smartContext)
            )
        let decision = capability == .blackBox || capability == .overloaded
            ? nil
            : snapshot.detectDecision(
                bundleID: focus.bundleID,
                windowTitle: focus.windowTitle,
                config: ContextDetectionConfig(settings: settings.value.smartContext)
            )
        let contextKind = decision?.kind ?? .unknown
        let smartJudgmentAvailable = capability.canUseSmartLanguageJudgment
        manualOverride = true
        manualOverrideContextKind = contextKind
        manualOverrideWindowKey = focus.key.raw

        resolver.recordWindowMemory(focus: focus, sourceID: sourceID)

        if let lastAutomaticSwitch,
           lastAutomaticSwitch.windowKey == focus.key.raw,
           lastAutomaticSwitch.lang != lang,
           Date().timeIntervalSince(lastAutomaticSwitch.at) <= negativeFeedbackInterval {
            resolver.recordNegativeFeedback(keys: lastAutomaticSwitch.keys, against: lastAutomaticSwitch.lang)
            self.lastAutomaticSwitch = nil
        }

        guard mode == .smart,
              settings.value.smartLearningEnabled,
              smartJudgmentAvailable,
              !learnedCurrentFocusEntry
        else { return }

        let keys = smartKeysForFocus(focus, contextKind)
        guard !keys.lookupOrder.isEmpty else { return }
        currentSmartKeys = keys
        resolver.recordManualCorrection(keys: keys, lang: lang)
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

        let startedAt = Date()
        defer {
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            logger.debug("eval done trig=\(self.triggerLabel(trigger), privacy: .public) elapsed_ms=\(elapsedMs, privacy: .public)")
        }

        let windowKey = focus.key.raw
        let windowIdentityChanged = windowKey != lastWindowKey
        lastWindowKey = windowKey
        let contextConfig = ContextDetectionConfig(settings: settings.value.smartContext)
        let scope = triggerScope(trigger: trigger, windowIdentityChanged: windowIdentityChanged)
        let resolvedSnapshot = await snapshotWithRetry(focus: focus, scope: scope, config: contextConfig)
        guard !Task.isCancelled else { return }
        let snapshot = resolvedSnapshot.snapshot
        let capability = resolvedSnapshot.capability
        let contextDecision = resolvedSnapshot.decision

        let contextKind = contextDecision?.kind ?? .unknown
        let smartJudgmentAvailable = capability.canUseSmartLanguageJudgment
        updateStateForTrigger(
            focus: focus,
            trigger: trigger,
            scope: scope,
            contextKind: contextKind,
            smartJudgmentAvailable: smartJudgmentAvailable,
            windowKey: windowKey
        )

        let rule = settings.rule(for: focus.bundleID)
        let mode = rule?.mode ?? settings.value.defaultMode

        if scope.isFocusEntry {
            logger.debug("eval trig=\(self.triggerLabel(trigger), privacy: .public) mode=\(mode.rawValue, privacy: .public) override=\(self.manualOverride, privacy: .public) ax=\(capability.rawValue, privacy: .public) smart=\(smartJudgmentAvailable, privacy: .public) context=\(contextKind.rawValue, privacy: .public) source=\(contextDecision?.source ?? "nil", privacy: .public) \(SmartLearningKeyBuilder.trace(bundleID: focus.bundleID, element: focus.element, contextKind: contextKind), privacy: .public)")
        }

        let target = resolveTarget(
            focus: focus,
            trigger: trigger,
            scope: scope,
            mode: mode,
            rule: rule,
            contextKind: contextKind,
            contextDecision: contextDecision,
            smartJudgmentAvailable: smartJudgmentAvailable,
            windowKey: windowKey,
            sourceFor: source
        )

        guard let target else { return }
        if target == sources.currentID { return }
        guard shouldSwitch(
            target: target,
            chineseSourceID: zh,
            englishSourceID: en,
            trigger: trigger,
            scope: scope,
            decision: contextDecision,
            snapshot: snapshot,
            focus: focus
        ) else { return }

        await selectTarget(
            target,
            mode: mode,
            smartJudgmentAvailable: smartJudgmentAvailable,
            isFocusEntry: scope.isFocusEntry,
            windowKey: windowKey
        )
    }

    private func resolveTarget(
        focus: FocusTracker.Focus,
        trigger: FocusTracker.Trigger,
        scope: TriggerScope,
        mode: AppMode,
        rule: AppRule?,
        contextKind: ContextKind,
        contextDecision: ContextDecision?,
        smartJudgmentAvailable: Bool,
        windowKey: String,
        sourceFor source: (LangChoice) -> String
    ) -> String? {
        var target: String?

        switch mode {
        case .forceEnglish:
            if scope.isFocusEntry { target = source(.english) }
        case .forceChinese:
            if scope.isFocusEntry { target = source(.chinese) }
        default:
            break
        }

        let keywordTrigger = scope.isFocusEntry || trigger == .titleChanged
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
            guard smartJudgmentAvailable else { break }
            // 智能判定在进入焦点时运行；对明确的上下文变化/内容变化也允许重判，
            // 这样 Codex 对话输入、终端 prompt、Agent 区域能随实际上下文切换。
            guard scope.isSmartTrigger else { break }
            if target == nil,
               scope.isFocusEntry,
               settings.value.smartLearningEnabled,
               let learned = resolver.learnedLanguage(for: currentSmartKeys) {
                // 已学值优先级最高：用户曾为该组件纠正过的语言直接恢复
                target = source(learned.lang)
                manualOverrideContextKind = contextKind
                manualOverrideWindowKey = windowKey
            } else if target == nil,
                      !manualOverride,
                      (scope.isFocusEntry || isStrongContext(contextKind)),
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

        let smartModeFallsBackToMemory = mode == .smart && !smartJudgmentAvailable

        // 4. 记忆等非智能模式下也能识别终端；终端更适合按当前行/agent 状态实时判定，
        // 而不是记住一次性的窗口输入源。
        if target == nil,
           mode == .memory,
           scope.isSmartTrigger,
           !manualOverride,
           let terminalLang = contextDecision?.lang,
           contextKind == .terminalShell || contextKind == .terminalAgent {
            target = source(terminalLang == .chinese ? .chinese : .english)
            manualOverrideContextKind = contextKind
            manualOverrideWindowKey = windowKey
        }

        // 5. 窗口记忆 / 应用默认：
        // 智能模式在 AX 读不到真实上下文时直接回退到窗口记忆；
        // 其余模式仍只在进入窗口时恢复，避免与窗口内手动切换冲突。
        if target == nil, scope.isWindowEntry || smartModeFallsBackToMemory {
            target = resolver.fallback(focus: focus, rule: rule, sourceFor: source)?.sourceID
        }

        return target
    }

    private func triggerScope(trigger: FocusTracker.Trigger, windowIdentityChanged: Bool) -> TriggerScope {
        let isWindowEntry = trigger == .appActivated
            || trigger == .windowChanged
            || (trigger == .elementChanged && windowIdentityChanged)
        let isFocusEntry = isWindowEntry || trigger == .elementChanged
        let isContentChange = trigger == .titleChanged || trigger == .selectionChanged
        return TriggerScope(
            isWindowEntry: isWindowEntry,
            isFocusEntry: isFocusEntry,
            isContentChange: isContentChange,
            isSmartTrigger: isFocusEntry || isContentChange,
            contentChangeProtectedByTyping: isContentChange && secondsSinceLastKeyDown() < typingProtectionInterval
        )
    }

    private func snapshotWithRetry(
        focus: FocusTracker.Focus,
        scope: TriggerScope,
        config: ContextDetectionConfig
    ) async -> (snapshot: ContextDetector.FocusSnapshot, capability: AXCapability, decision: ContextDecision?) {
        let mode = loadGovernor.samplingMode(for: focus.bundleID)
        var snapshot = snapshotForFocus(focus, mode)

        // 完整采样才记录负载，用于判定该应用是否太贵；`minimal` 模式天然便宜，不能用来解除暂停。
        if mode == .full {
            loadGovernor.record(snapshot.load, bundleID: focus.bundleID, appName: focus.appName)
        }

        // 重新检查采样模式：刚才可能刚好踩线触发暂停。
        let actualMode = loadGovernor.samplingMode(for: focus.bundleID)
        var capability = actualMode == .minimal
            ? AXCapability.overloaded
            : axCapabilityForFocus(focus, snapshot, config)
        var decision = capability == .blackBox || capability == .overloaded
            ? nil
            : snapshot.detectDecision(bundleID: focus.bundleID, windowTitle: focus.windowTitle, config: config)

        if capability == .blackBox, scope.isFocusEntry, actualMode == .full {
            await waitBeforeBlackBoxRetry()
            guard !Task.isCancelled else { return (snapshot, capability, decision) }
            let retrySnapshot = snapshotForFocus(focus, .full)
            loadGovernor.record(retrySnapshot.load, bundleID: focus.bundleID, appName: focus.appName)
            let retryMode = loadGovernor.samplingMode(for: focus.bundleID)
            let retryCapability = retryMode == .minimal
                ? AXCapability.overloaded
                : axCapabilityForFocus(focus, retrySnapshot, config)
            if retryCapability != .blackBox {
                snapshot = retrySnapshot
                capability = retryCapability
                decision = retryCapability == .overloaded
                    ? nil
                    : retrySnapshot.detectDecision(bundleID: focus.bundleID, windowTitle: focus.windowTitle, config: config)
                logger.debug("blackbox retry recovered ax=\(retryCapability.rawValue, privacy: .public)")
            }
        }

        return (snapshot, capability, decision)
    }

    private func updateStateForTrigger(
        focus: FocusTracker.Focus,
        trigger: FocusTracker.Trigger,
        scope: TriggerScope,
        contextKind: ContextKind,
        smartJudgmentAvailable: Bool,
        windowKey: String
    ) {
        if scope.isWindowEntry {
            manualOverride = false
            manualOverrideWindowKey = nil
            manualOverrideContextKind = contextKind
            learnedCurrentFocusEntry = false
            currentContextKind = contextKind
            currentSmartKeys = smartJudgmentAvailable ? smartKeysForFocus(focus, contextKind) : SmartLearningKeyBuilder.Keys()
        } else if trigger == .elementChanged {
            if contextKind != currentContextKind || manualOverrideWindowKey != windowKey {
                manualOverride = false
                manualOverrideWindowKey = nil
                manualOverrideContextKind = contextKind
            }
            learnedCurrentFocusEntry = false
            currentContextKind = contextKind
            currentSmartKeys = smartJudgmentAvailable ? smartKeysForFocus(focus, contextKind) : SmartLearningKeyBuilder.Keys()
        } else if scope.isContentChange, !scope.contentChangeProtectedByTyping, contextKind != currentContextKind {
            manualOverride = false
            manualOverrideWindowKey = nil
            manualOverrideContextKind = contextKind
            currentContextKind = contextKind
            currentSmartKeys = smartJudgmentAvailable ? smartKeysForFocus(focus, contextKind) : SmartLearningKeyBuilder.Keys()
        }
    }

    private func shouldSwitch(
        target: String,
        chineseSourceID: String,
        englishSourceID: String,
        trigger: FocusTracker.Trigger,
        scope: TriggerScope,
        decision: ContextDecision?,
        snapshot: ContextDetector.FocusSnapshot,
        focus: FocusTracker.Focus
    ) -> Bool {
        if shouldSkipForPinyinComposition(
            target: target,
            chineseSourceID: chineseSourceID,
            englishSourceID: englishSourceID,
            trigger: trigger,
            decision: decision,
            snapshot: snapshot
        ) {
            logger.debug("skip switch during pinyin composition trigger=\(self.triggerLabel(trigger), privacy: .public)")
            return false
        }
        if scope.contentChangeProtectedByTyping {
            logger.debug("skip switch during recent typing trigger=\(self.triggerLabel(trigger), privacy: .public)")
            return false
        }
        guard focusIsStillCurrent(focus) else {
            logger.debug("skip stale switch trigger=\(self.triggerLabel(trigger), privacy: .public)")
            return false
        }
        return true
    }

    private func selectTarget(
        _ target: String,
        mode: AppMode,
        smartJudgmentAvailable: Bool,
        isFocusEntry: Bool,
        windowKey: String
    ) async {
        if await sources.select(id: target),
           mode == .smart,
           smartJudgmentAvailable,
           let selectedLang = lang(for: target) {
            lastAutomaticSwitch = (currentSmartKeys, selectedLang, windowKey, Date())
            if isFocusEntry {
                resolver.reinforce(keys: currentSmartKeys, lang: selectedLang)
            }
        }
    }

    private func shouldSkipForPinyinComposition(
        target: String,
        chineseSourceID: String,
        englishSourceID: String,
        trigger: FocusTracker.Trigger,
        decision: ContextDecision?,
        snapshot: ContextDetector.FocusSnapshot
    ) -> Bool {
        guard target == englishSourceID,
              sources.currentID == chineseSourceID,
              trigger == .selectionChanged || trigger == .titleChanged,
              decision?.source == "cursor-text",
              let cursorText = snapshot.cursorText
        else { return false }
        return looksLikePinyinComposition(cursorText)
    }

    private func looksLikePinyinComposition(_ text: String) -> Bool {
        let token = text
            .split { !$0.isLetter }
            .last
            .map(String.init) ?? ""
        guard (2...24).contains(token.count) else { return false }
        return token.unicodeScalars.allSatisfy { scalar in
            (0x61...0x7A).contains(scalar.value)
        }
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

    private func focusIsStillCurrent(_ focus: FocusTracker.Focus) -> Bool {
        guard let pid = focus.processID, let expected = focus.element else { return true }
        guard let current = focusedElementForProcess(pid) else { return false }
        return CFEqual(current, expected)
    }
}

enum KeywordMatcher {
    static func match(in haystack: String, rules: [KeywordRule]) -> LangChoice? {
        rules.first {
            !$0.keyword.isEmpty && haystack.localizedCaseInsensitiveContains($0.keyword)
        }?.lang
    }
}
