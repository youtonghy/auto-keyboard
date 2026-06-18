import ApplicationServices
import Foundation
import os

@MainActor
final class RuleEngine {
    private let settings: SettingsStore
    private let sources: InputSourceManaging
    private let memory: WindowStateStoring
    private let smartLearning: SmartLearningStoring
    private let smartKeyForFocus: (FocusTracker.Focus, ContextKind) -> SmartLearningKey?
    private let capabilityForFocus: (FocusTracker.Focus) -> AXCapability
    private let decisionForFocus: (FocusTracker.Focus, AXCapability) -> ContextDecision?
    private let clickInputCandidateForHitElement: (AXUIElement?) -> Bool?
    private let caretLocationForFocus: (FocusTracker.Focus, AXUIElement?) -> AXGeometry.CaretLocation?
    private let screenCaptureTrustedForOCR: () -> Bool
    private let ocrDebugTokenFactory: () -> String
    private let fileLogger: FileLogger

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
    private var manualOverrideAt: Date?
    private static let manualOverrideTTL: TimeInterval = 1.5

    /// OCR 引擎与节流：OCR 较重，仅在 AX 取不到文本时兜底，并按最小间隔节流，避免连发光标事件刷爆。
    private let ocrRunner: (CGRect, CGRect, String?) async -> String?
    private var lastOCRAt: Date?
    private var lastOCRAnchor: String?
    private static let ocrMinInterval: TimeInterval = 0.5

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
        },
        capabilityForFocus: @escaping (FocusTracker.Focus) -> AXCapability = {
            ContextDetector.axCapability(bundleID: $0.bundleID, element: $0.element, window: $0.window)
        },
        decisionForFocus: @escaping (FocusTracker.Focus, AXCapability) -> ContextDecision? = { focus, capability in
            guard capability != .blackBox else { return nil }
            return ContextDetector.detectDecision(
                bundleID: focus.bundleID,
                element: focus.element,
                window: focus.window,
                windowTitle: focus.windowTitle
            )
        },
        clickInputCandidateForHitElement: @escaping (AXUIElement?) -> Bool? = {
            ContextDetector.isClickInputCandidate(element: $0)
        },
        caretLocationForFocus: @escaping (FocusTracker.Focus, AXUIElement?) -> AXGeometry.CaretLocation? = { focus, hitElement in
            AXGeometry.caretScreenRect(
                element: focus.element,
                hitElement: hitElement ?? focus.hitElement,
                focusPoint: focus.focusPoint,
                window: focus.window
            )
        },
        screenCaptureTrustedForOCR: @escaping () -> Bool = {
            Permissions.screenCaptureTrusted
        },
        ocrDebugTokenFactory: @escaping () -> String = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
                .replacingOccurrences(of: ".", with: "-")
        },
        ocrDebugArtifactDirectory: URL? = nil,
        ocrRunner: ((CGRect, CGRect, String?) async -> String?)? = nil,
        fileLogger: FileLogger = FileLogger()
    ) {
        self.settings = settings
        self.sources = sources
        self.memory = memory
        self.smartLearning = smartLearning
        self.smartKeyForFocus = smartKeyForFocus
        self.capabilityForFocus = capabilityForFocus
        self.decisionForFocus = decisionForFocus
        self.clickInputCandidateForHitElement = clickInputCandidateForHitElement
        self.caretLocationForFocus = caretLocationForFocus
        self.screenCaptureTrustedForOCR = screenCaptureTrustedForOCR
        self.ocrDebugTokenFactory = ocrDebugTokenFactory
        if let ocrRunner {
            self.ocrRunner = ocrRunner
        } else {
            self.ocrRunner = { caretRect, captureRect, token in
                await OCREngine(debugArtifactDirectory: ocrDebugArtifactDirectory)
                    .recognize(caretScreenRect: caretRect, captureRect: captureRect, debugToken: token)
            }
        }
        self.fileLogger = fileLogger
    }

    func noteManualSwitch(sourceID: String, focus: FocusTracker.Focus?) {
        guard settings.value.enabled,
              let focus,
              let lang = lang(for: sourceID)
        else {
            manualOverride = true
            manualOverrideAt = Date()
            return
        }

        let rule = settings.rule(for: focus.bundleID)
        let mode = rule?.mode ?? settings.value.defaultMode
        guard mode != .forceEnglish, mode != .forceChinese else {
            manualOverride = true
            return
        }

        let capability = capabilityForFocus(focus)
        let decision = decisionForFocus(focus, capability)
        let contextKind = decision?.kind ?? .unknown
        manualOverride = true
        manualOverrideContextKind = contextKind
        manualOverrideWindowKey = focus.key.raw
        manualOverrideAt = Date()

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
        let capability = capabilityForFocus(focus)
        let contextDecision = decisionForFocus(focus, capability)
        let contextKind = contextDecision?.kind ?? .unknown
        let axDecisionIsWeak = capability.prefersOCRInSmartMode
        let clickIntent = clickIntent(for: focus)
        let inputIntent = inputIntent(for: focus, clickIntent: clickIntent)
        let shouldAllowOCRNow = shouldAllowOCR(capability: capability, trigger: trigger, inputIntent: inputIntent)

        let isClickEntry = (trigger == .elementChanged || trigger == .mouseDown) && focus.focusPoint != nil
        let isWindowEntry = trigger == .appActivated
            || trigger == .windowChanged
            || (trigger == .elementChanged && windowIdentityChanged)
        let isFocusEntry = isWindowEntry || trigger == .elementChanged || isClickEntry
        let isContentChange = trigger == .titleChanged || trigger == .selectionChanged || trigger == .valueChanged
        let isSmartTrigger = isFocusEntry || isContentChange
        if manualOverride,
           capability == .blackBox,
           trigger == .elementChanged,
           inputIntent == .input,
           manualOverrideWindowKey == windowKey {
            manualOverride = false
            manualOverrideContextKind = contextKind
            manualOverrideAt = nil
        }
        if manualOverride,
           let manualOverrideAt,
           trigger == .elementChanged,
           inputIntent == .input,
           manualOverrideWindowKey == windowKey,
           Date().timeIntervalSince(manualOverrideAt) > Self.manualOverrideTTL {
            manualOverride = false
            manualOverrideWindowKey = nil
            manualOverrideContextKind = contextKind
            self.manualOverrideAt = nil
        }
        if isWindowEntry {
            // 进入新窗口/应用：完全重置，恢复自动判定
            manualOverride = false
            manualOverrideWindowKey = nil
            manualOverrideContextKind = contextKind
            manualOverrideAt = nil
            learnedCurrentFocusEntry = false
            currentContextKind = contextKind
            currentSmartKey = capability == .blackBox ? nil : smartKeyForFocus(focus, contextKind)
        } else if trigger == .elementChanged || trigger == .mouseDown {
            if contextKind != currentContextKind || manualOverrideWindowKey != windowKey {
                manualOverride = false
                manualOverrideWindowKey = nil
                manualOverrideContextKind = contextKind
                manualOverrideAt = nil
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
            manualOverrideAt = nil
            currentContextKind = contextKind
            currentSmartKey = capability == .blackBox ? nil : smartKeyForFocus(focus, contextKind)
        }

        let rule = settings.rule(for: focus.bundleID)
        let mode = rule?.mode ?? settings.value.defaultMode

        if isFocusEntry {
            logger.debug("eval trig=\(self.triggerLabel(trigger), privacy: .public) mode=\(mode.rawValue, privacy: .public) override=\(self.manualOverride, privacy: .public) ax=\(capability.rawValue, privacy: .public) weak=\(axDecisionIsWeak, privacy: .public) click=\(self.clickIntentLabel(clickIntent), privacy: .public) input=\(self.inputIntentLabel(inputIntent), privacy: .public) allowOCR=\(shouldAllowOCRNow, privacy: .public) context=\(contextKind.rawValue, privacy: .public) source=\(contextDecision?.source ?? "nil", privacy: .public) \(self.focusSummary(focus), privacy: .public)")
        }

        if isSmartTrigger {
            debugLog("eval trig=\(triggerLabel(trigger)) bundle=\(focus.bundleID) title=\"\(focus.windowTitle)\" ax=\(capability.rawValue) weak=\(axDecisionIsWeak) click=\(clickIntentLabel(clickIntent)) input=\(inputIntentLabel(inputIntent)) allowOCR=\(shouldAllowOCRNow) override=\(manualOverride) mode=\(mode.rawValue) ctxSrc=\(contextDecision?.source ?? "nil") ctxLang=\(langLabel(contextDecision?.lang)) cur=\(sources.currentID) \(focusSummary(focus))")
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

        let keywordTrigger = isFocusEntry || trigger == .titleChanged || trigger == .selectionChanged
        func keywordTarget() -> String? {
            guard keywordTrigger, let rule, !rule.keywordRules.isEmpty else { return nil }
            let key = focus.key.raw
            let haystack = ContextDetector.keywordHaystack(element: focus.element, windowTitle: focus.windowTitle)
            let match = KeywordMatcher.match(in: haystack, rules: rule.keywordRules)
            let previous = lastKeywordMatch[key]
            if match != previous {
                if lastKeywordMatch.count > 1000 { lastKeywordMatch.removeAll() }
                lastKeywordMatch[key] = match
                if let match {
                    return source(match)
                } else if previous != nil, let def = rule.defaultLang {
                    // 关键词消失（如 claude/codex 退出）→ 回到应用默认
                    return source(def)
                }
            }
            return nil
        }

        func learnedTarget() -> String? {
            guard isFocusEntry,
                  settings.value.smartLearningEnabled,
                  let key = currentSmartKey,
                  let learned = smartLearning.lookup(key)
            else { return nil }
            manualOverrideContextKind = contextKind
            manualOverrideWindowKey = windowKey
            return source(learned)
        }

        func detectedTarget() -> String? {
            guard !manualOverride,
                  (isFocusEntry || isStrongContext(contextKind)),
                  let detected = contextDecision?.lang
            else { return nil }
            manualOverrideContextKind = contextKind
            manualOverrideWindowKey = windowKey
            return source(detected == .chinese ? .chinese : .english)
        }

        func ocrTarget() async -> String? {
            guard settings.value.ocrAssistedDetection else { return nil }
            if !screenCaptureTrustedForOCR() {
                debugLog("ocr skip: screen capture not trusted")
                return nil
            }
            if !isSmartTrigger {
                debugLog("ocr skip: not a smart trigger")
                return nil
            }
            if manualOverride {
                debugLog("ocr skip: manual override active")
                return nil
            }
            guard shouldAllowOCR(capability: capability, trigger: trigger, inputIntent: inputIntent) else {
                debugLog("ocr skip: input-intent gate blocked")
                return nil
            }
            guard let caret = caretLocationForFocus(focus, focus.hitElement) else {
                debugLog("ocr skip: caretScreenRect nil (no element/window bounds)")
                return nil
            }
            let anchor = ocrAnchor(windowKey: windowKey, caret: caret.rect)
            guard ocrCooldownReady(anchor: anchor) else {
                debugLog("ocr skip: cooldown")
                return nil
            }
            lastOCRAt = Date()
            lastOCRAnchor = anchor
            let captureRect = AXGeometry.captureRect(around: caret.rect)
            let token = ocrDebugTokenFactory()
            debugLog("ocr run: token=\(token) caretSrc=\(caret.source) caretRect=\(AX.formatRect(caret.rect)) capture=\(AX.formatRect(captureRect)) input=\(inputIntentLabel(inputIntent)) click=\(clickIntentLabel(clickIntent)) focusPoint=\(focus.focusPoint.map(AX.formatPoint) ?? "nil") hit=\(AX.debugSummary(focus.hitElement)) element=\(AX.debugSummary(focus.element))")
            let ocrText = await ocrRunner(caret.rect, captureRect, token)
            if Task.isCancelled {
                debugLog("ocr cancelled")
                return nil
            }
            guard let ocrText else {
                debugLog("ocr returned no text")
                return nil
            }
            let preview = ocrText.replacingOccurrences(of: "\n", with: " ⏎ ")
            let decision = ContextDetector.ocrDecision(text: ocrText)
            debugLog("ocr text(\(ocrText.count))=\"\(preview.prefix(120))\" decision=\(langLabel(decision?.lang))")
            guard let decision else { return nil }
            manualOverrideContextKind = decision.kind
            manualOverrideWindowKey = windowKey
            debugLog("ocr accept: token=\(token) kind=\(decision.kind.rawValue) lang=\(langLabel(decision.lang)) window=\(windowKey)")
            return source(decision.lang == .chinese ? .chinese : .english)
        }

        // 2. 上下文关键词。非智能模式仍保留显式关键词规则；智能模式在下方按指定顺序处理。
        if target == nil, mode != .smart {
            target = keywordTarget()
        }

        // 3. 智能模式：AX 可读时 学习 > 关键词 > 识别；黑盒应用直接 OCR。
        switch mode {
        case .smart:
            guard isSmartTrigger else { break }
            if shouldUseOCR(capability: capability, trigger: trigger, inputIntent: inputIntent) {
                target = await ocrTarget()
            } else {
                target = learnedTarget()
                    ?? keywordTarget()
                    ?? detectedTarget()
            }
        default:
            break
        }

        // 4. 窗口记忆 / 应用默认（仅在进入窗口时恢复，避免与窗口内手动切换冲突）
        if target == nil, isWindowEntry {
            target = memory.lookup(focus.key) ?? (rule?.defaultLang).map(source)
        }

        let willSwitch = target != nil && target != sources.currentID
        debugLog("eval done: target=\(target ?? "nil") current=\(sources.currentID) willSwitch=\(willSwitch)")
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
        case .valueChanged: "value"
        case .mouseDown: "down"
        }
    }

    private func focusSummary(_ focus: FocusTracker.Focus) -> String {
        let hitRole = focus.hitElement.flatMap { AX.copyString($0, kAXRoleAttribute as String) } ?? "nil"
        let focusPoint = focus.focusPoint.map { "(\(Int($0.x)),\(Int($0.y)))" } ?? "nil"
        return "bundle=\(focus.bundleID) title=\"\(focus.windowTitle)\" focusPoint=\(focusPoint) hitRole=\(hitRole)"
    }

    private func clickIntentLabel(_ intent: Bool) -> String {
        intent ? "click" : "no-click"
    }

    private func isStrongContext(_ kind: ContextKind) -> Bool {
        switch kind {
        case .assistantChatInput, .terminalShell, .terminalAgent, .ocrContext:
            true
        case .normalTextInput, .unknown:
            false
        }
    }

    /// OCR 节流：同一窗口同一锚点短时间内跳过；不同点击点不互相压制。
    private func ocrCooldownReady(anchor: String) -> Bool {
        guard let last = lastOCRAt else { return true }
        guard lastOCRAnchor == anchor else { return true }
        return Date().timeIntervalSince(last) >= Self.ocrMinInterval
    }

    private func ocrAnchor(windowKey: String, caret: CGRect) -> String {
        let bucket: CGFloat = 24
        let x = Int((caret.midX / bucket).rounded())
        let y = Int((caret.midY / bucket).rounded())
        return "\(windowKey)|\(x)|\(y)"
    }

    /// 文件调试日志（仅在设置中开启「调试日志」时写入）。
    private func debugLog(_ message: String) {
        guard settings.value.debugLogging else { return }
        fileLogger.log(message)
    }

    private func langLabel(_ lang: DetectedLang?) -> String {
        switch lang {
        case .chinese: "中文"
        case .english: "英文"
        case .none: "nil"
        }
    }

    private enum InputIntent {
        case input
        case nonInput
        case unknown
    }

    private func clickIntent(for focus: FocusTracker.Focus) -> Bool {
        guard focus.focusPoint != nil else { return false }
        return true
    }

    private func inputIntent(for focus: FocusTracker.Focus, clickIntent: Bool) -> InputIntent {
        guard clickIntent else { return .unknown }
        guard let hitElement = focus.hitElement else { return .unknown }
        if let explicit = clickInputCandidateForHitElement(hitElement) {
            return explicit ? .input : .nonInput
        }
        if let role = AX.copyString(hitElement, kAXRoleAttribute as String),
           let subrole = AX.copyString(hitElement, kAXSubroleAttribute as String),
           ContextDetector.isBlackBoxScrollAreaInputCandidate(bundleID: focus.bundleID, role: role, subrole: subrole) {
            return blackBoxInputDescendant(in: hitElement) != nil ? .input : .unknown
        }
        if isTextLikeHitElement(hitElement) {
            return .input
        }
        return .unknown
    }

    private func isTextLikeHitElement(_ element: AXUIElement) -> Bool {
        let role = AX.copyString(element, kAXRoleAttribute as String) ?? ""
        let subrole = AX.copyString(element, kAXSubroleAttribute as String) ?? ""
        let lowerRole = role.lowercased()
        let lowerSubrole = subrole.lowercased()
        if lowerRole.contains("text")
            || lowerRole.contains("editor")
            || lowerRole.contains("field")
            || lowerRole.contains("content")
            || lowerSubrole.contains("text")
        {
            return true
        }
        if AX.copyRange(element, kAXSelectedTextRangeAttribute as String) != nil
            || AX.copyString(element, kAXValueAttribute as String) != nil
            || AX.copyInt(element, kAXNumberOfCharactersAttribute as String) != nil {
            return true
        }
        return false
    }

    private func blackBoxInputDescendant(in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth < 4, let children = AX.copyChildren(element) else { return nil }
        for child in children {
            let role = AX.copyString(child, kAXRoleAttribute as String) ?? ""
            let subrole = AX.copyString(child, kAXSubroleAttribute as String)
            if let explicit = ContextDetector.isClickInputCandidate(role: role, subrole: subrole), explicit {
                return child
            }
            if let found = blackBoxInputDescendant(in: child, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    private func inputIntentLabel(_ intent: InputIntent) -> String {
        switch intent {
        case .input: "input"
        case .nonInput: "non-input"
        case .unknown: "unknown"
        }
    }

    private func shouldAllowOCR(capability: AXCapability, trigger: FocusTracker.Trigger, inputIntent: InputIntent) -> Bool {
        if inputIntent == .input {
            return true
        }
        if trigger == .mouseDown {
            return inputIntent != .nonInput
        }
        if capability.prefersOCRInSmartMode {
            switch inputIntent {
            case .nonInput:
                return false
            case .input, .unknown:
                return trigger == .elementChanged || trigger == .selectionChanged || trigger == .valueChanged
            }
        }
        guard capability.prefersOCRInSmartMode else { return false }
        switch inputIntent {
        case .input:
            return true
        case .nonInput:
            return false
        case .unknown:
            return trigger == .elementChanged || trigger == .selectionChanged || trigger == .valueChanged
        }
    }

    private func shouldUseOCR(capability: AXCapability, trigger: FocusTracker.Trigger, inputIntent: InputIntent) -> Bool {
        shouldAllowOCR(capability: capability, trigger: trigger, inputIntent: inputIntent)
    }
}

enum KeywordMatcher {
    static func match(in haystack: String, rules: [KeywordRule]) -> LangChoice? {
        rules.first {
            !$0.keyword.isEmpty && haystack.localizedCaseInsensitiveContains($0.keyword)
        }?.lang
    }
}
