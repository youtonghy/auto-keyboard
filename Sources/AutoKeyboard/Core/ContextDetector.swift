import ApplicationServices
import Foundation

enum DetectedLang: Equatable {
    case chinese
    case english
}

enum ContextKind: String, Hashable {
    case assistantChatInput
    case terminalShell
    case terminalAgent
    case normalTextInput
    case unknown
}

enum AXCapability: String, Hashable {
    case componentVisible
    case textVisible
    case blackBox
    case overloaded

    var label: String {
        switch self {
        case .componentVisible:
            "AX 智能可用"
        case .textVisible:
            "AX 不完整，使用窗口记忆"
        case .blackBox:
            "AX 黑盒，无法定位具体输入组件"
        case .overloaded:
            "AX 读取开销过大，已暂停智能模式"
        }
    }
}

extension AXCapability {
    var canUseSmartLanguageJudgment: Bool {
        self == .componentVisible
    }
}

struct ContextDecision: Equatable {
    let kind: ContextKind
    let lang: DetectedLang?
    let source: String
}

struct ContextDetectionConfig: Equatable {
    var terminalBundleIDs: Set<String>
    var multiContextHostBundleIDs: Set<String>
    var terminalAgentKeywords: [String]
    var chatSemanticKeywords: [String]

    init(settings: SmartContextSettings = SmartContextSettings()) {
        terminalBundleIDs = Set(settings.terminalBundleIDs)
        multiContextHostBundleIDs = Set(settings.multiContextHostBundleIDs)
        terminalAgentKeywords = settings.terminalAgentKeywords
        chatSemanticKeywords = settings.chatSemanticKeywords
    }

    static let `default` = ContextDetectionConfig()
}

@MainActor
enum ContextDetector {
    private static let keywordFieldLimit = 180
    private static let keywordTitleLimit = 500
    private static let keywordParentDepth = 4
    private static let focusRegionParentDepth = 12
    private static let textCollectionMaxDepth = 15
    private static let keywordAttributes = [
        kAXRoleAttribute as String,
        kAXSubroleAttribute as String,
        kAXTitleAttribute as String,
        kAXDescriptionAttribute as String,
        "AXIdentifier",
        "AXDOMIdentifier",
        "AXRoleDescription",
        "AXPlaceholderValue",
        kAXHelpAttribute as String,
        kAXValueAttribute as String,
    ]
    private static let terminalIdentityKeywords = [
        "terminal",
        "integrated terminal",
        "xterm",
        "pty",
        "bash",
        "zsh",
        "fish",
        "shell",
        "pwsh",
        "powershell",
    ]
    private static let shellPromptRegex = try! NSRegularExpression(
        pattern: #"(?:^|\s)(?:[➜→❯»$%#]|PS[^\n]*>)\s*$"#
    )
    private static let textRoles: Set<String> = [
        kAXStaticTextRole, kAXTextAreaRole, kAXTextFieldRole,
    ]
    private static let skipTextCollectionRoles: Set<String> = [
        kAXMenuBarRole, kAXMenuRole, kAXMenuItemRole, kAXToolbarRole,
        kAXButtonRole, kAXPopUpButtonRole, kAXMenuButtonRole,
        kAXScrollBarRole,
    ]
    private static let focusRegionContainerRoles: Set<String> = [
        kAXGroupRole, kAXScrollAreaRole,
        "AXSplitGroup", "AXWebArea", "AXOutline", "AXTable", "AXList",
        "AXCollection", "AXBrowser", "AXLayoutArea",
    ]
    private static let focusRegionTextRoles: Set<String> = [
        kAXTextAreaRole, kAXTextFieldRole,
    ]
    private static let secureTextRoles: Set<String> = [
        "AXSecureTextField",
    ]
    private static let focusRegionWindowBoundaryRoles: Set<String> = [
        kAXWindowRole, "AXSheet", "AXDrawer",
    ]
    private static let focusRegionChromeBoundaryRoles: Set<String> = [
        kAXMenuBarRole, kAXMenuRole, kAXMenuItemRole, kAXToolbarRole,
        kAXScrollBarRole,
    ]

    struct FocusRegionNode: Equatable {
        let role: String
        let subrole: String?
        let shortTexts: [String]

        init(role: String, subrole: String? = nil, shortTexts: [String] = []) {
            self.role = role
            self.subrole = subrole
            self.shortTexts = shortTexts
        }
    }

    private struct FocusRegionContext {
        let root: AXUIElement?
        let nodes: [FocusRegionNode]
    }

    private struct TextCollectionProfile {
        let charBudget: Int
        let nodeBudget: Int
        let childLimit: Int
        let earlyClassifyAfter: Int

        static let focusRegion = TextCollectionProfile(
            charBudget: 900,
            nodeBudget: 160,
            childLimit: 40,
            earlyClassifyAfter: 240
        )

        static let windowFallback = TextCollectionProfile(
            charBudget: 700,
            nodeBudget: 120,
            childLimit: 30,
            earlyClassifyAfter: 220
        )
    }

    struct FocusSnapshot {
        let elementNodes: [FocusRegionNode]
        let cursorText: String?
        let regionText: String?
        let windowText: String?
        let hasElement: Bool
        /// 本次采样的实际开销，供 `AXLoadGovernor` 判断该应用是否太贵。
        var load: AXLoadSample = .zero

        /// 采集一次焦点快照。
        ///
        /// `mode` 为 `.minimal` 时只读光标文本与祖先链（读取次数有硬上限），
        /// 跳过焦点区域与窗口正文的树遍历——用于已被判定"太贵"的应用，
        /// 避免持续读取 UI 把系统拖卡。
        @MainActor
        static func collect(
            element: AXUIElement?,
            window: AXUIElement?,
            mode: AXSamplingMode = .full
        ) -> FocusSnapshot {
            let meter = AXReadMeter()
            let startedAt = ContinuousClock.now
            let cursorText = element.flatMap { textNearCursor($0, meter: meter) }
            let focusContext = element.map { focusRegionContext(from: $0, meter: meter) }
            let regionText = mode == .full
                ? focusContext?.root.map { collectText(root: $0, profile: .focusRegion, meter: meter) }
                : nil
            let windowText = mode == .full ? window.map { collectWindowText($0, meter: meter) } : nil
            let emergencyAborted = meter.shouldAbort()
            return FocusSnapshot(
                elementNodes: focusContext?.nodes ?? [],
                cursorText: cursorText,
                regionText: regionText,
                windowText: windowText,
                hasElement: element != nil,
                load: AXLoadSample(
                    axReads: meter.reads,
                    elapsed: AXLoadSample.elapsed(since: startedAt),
                    emergencyAborted: emergencyAborted
                )
            )
        }

        @MainActor
        func axCapability(bundleID: String? = nil, config: ContextDetectionConfig = .default) -> AXCapability {
            ContextDetector.axCapability(
                bundleID: bundleID,
                elementNodes: elementNodes,
                cursorText: cursorText,
                regionText: regionText,
                windowText: windowText,
                hasElement: hasElement,
                config: config
            )
        }

        @MainActor
        func detectDecision(
            bundleID: String? = nil,
            windowTitle: String,
            config: ContextDetectionConfig = .default
        ) -> ContextDecision? {
            ContextDetector.detectDecision(
                bundleID: bundleID,
                windowTitle: windowTitle,
                elementNodes: elementNodes,
                cursorText: cursorText,
                regionText: regionText,
                windowText: windowText,
                hasElement: hasElement,
                config: config
            )
        }
    }

    /// 智能上下文判定：输入语义 → 输入正文 → 焦点区域正文 → 窗口可见内容 → 窗口标题
    static func detect(
        bundleID: String? = nil,
        element: AXUIElement?,
        window: AXUIElement?,
        windowTitle: String,
        config: ContextDetectionConfig = .default,
        mode: AXSamplingMode = .full
    ) -> DetectedLang? {
        detectDecision(
            bundleID: bundleID,
            element: element,
            window: window,
            windowTitle: windowTitle,
            config: config,
            mode: mode
        )?.lang
    }

    static func detectDecision(
        bundleID: String? = nil,
        element: AXUIElement?,
        window: AXUIElement?,
        windowTitle: String,
        config: ContextDetectionConfig = .default,
        mode: AXSamplingMode = .full
    ) -> ContextDecision? {
        FocusSnapshot.collect(element: element, window: window, mode: mode)
            .detectDecision(bundleID: bundleID, windowTitle: windowTitle, config: config)
    }

    static func axCapability(
        bundleID: String? = nil,
        element: AXUIElement?,
        window: AXUIElement?,
        config: ContextDetectionConfig = .default,
        mode: AXSamplingMode = .full
    ) -> AXCapability {
        FocusSnapshot.collect(element: element, window: window, mode: mode)
            .axCapability(bundleID: bundleID, config: config)
    }

    static func axCapability(
        bundleID: String? = nil,
        elementNodes: [FocusRegionNode],
        cursorText: String?,
        regionText: String?,
        windowText: String?,
        hasElement: Bool,
        config: ContextDetectionConfig = .default
    ) -> AXCapability {
        if hasComponentSignal(elementNodes: elementNodes, hasElement: hasElement) {
            return .componentVisible
        }
        if hasVisibleText(cursorText) || hasVisibleText(regionText) || hasVisibleText(windowText) {
            return .textVisible
        }
        if isElectronLikeHost(bundleID, config: config) {
            return .blackBox
        }
        return .textVisible
    }

    static func detectDecision(
        bundleID: String? = nil,
        windowTitle: String,
        elementNodes: [FocusRegionNode],
        cursorText: String?,
        regionText: String?,
        windowText: String? = nil,
        hasElement: Bool = true,
        config: ContextDetectionConfig = .default
    ) -> ContextDecision? {
        let haystack = keywordHaystack(windowTitle: windowTitle, elementNodes: elementNodes)
        let semanticText = semanticHaystack(windowTitle: windowTitle, elementNodes: elementNodes)
        let terminalDecision = detectTerminalDecision(
            bundleID: bundleID,
            haystack: haystack,
            text: cursorText,
            regionText: regionText ?? windowText,
            config: config
        )
        if hasSecureTextField(elementNodes) {
            return ContextDecision(kind: .normalTextInput, lang: .english, source: "secure-field")
        }
        if let terminalDecision {
            return terminalDecision
        }
        if let cursorText, let lang = classify(cursorText) {
            return ContextDecision(kind: .normalTextInput, lang: lang, source: "cursor-text")
        }
        if isAssistantChatContext(bundleID: bundleID, semanticText: semanticText, haystack: haystack, hasElement: hasElement, config: config) {
            return ContextDecision(kind: .assistantChatInput, lang: .chinese, source: "assistant-chat")
        }
        if let regionText, let lang = classify(regionText) {
            return ContextDecision(kind: .normalTextInput, lang: lang, source: "focus-region")
        }
        if let windowText, let lang = classify(windowText) {
            return ContextDecision(kind: .normalTextInput, lang: lang, source: "window-text")
        }
        if (hasElement || !isElectronLikeHost(bundleID, config: config)), let lang = classify(windowTitle) {
            return ContextDecision(kind: .normalTextInput, lang: lang, source: "window-title")
        }
        return nil
    }

    static func detectTerminal(
        bundleID: String?,
        element: AXUIElement?,
        windowTitle: String,
        config: ContextDetectionConfig = .default
    ) -> DetectedLang? {
        detectTerminalDecision(bundleID: bundleID, element: element, windowTitle: windowTitle, config: config)?.lang
    }

    static func detectTerminalDecision(
        bundleID: String?,
        element: AXUIElement?,
        windowTitle: String,
        config: ContextDetectionConfig = .default
    ) -> ContextDecision? {
        let meter = AXReadMeter()
        let cursorText = element.flatMap { textNearCursor($0, meter: meter) }
        let focusContext = element.map { focusRegionContext(from: $0, meter: meter) }
        let nodes = focusContext?.nodes ?? []
        return detectTerminalDecision(
            bundleID: bundleID,
            haystack: keywordHaystack(windowTitle: windowTitle, elementNodes: nodes),
            text: cursorText,
            regionText: focusContext?.root.map { collectText(root: $0, profile: .focusRegion, meter: meter) },
            config: config
        )
    }

    /// 上下文关键词匹配文本：窗口标题 → 当前焦点元素短属性 → 父级区域短属性。
    /// 只收集短元数据，避免把整段代码、终端输出或聊天正文当成关键词来源。
    static func keywordHaystack(element: AXUIElement?, windowTitle: String) -> String {
        let meter = AXReadMeter()
        return keywordHaystack(
            windowTitle: windowTitle,
            elementNodes: element.map { focusRegionContext(from: $0, meter: meter) }?.nodes ?? []
        )
    }

    static func keywordHaystack(windowTitle: String, elementShortTexts: [[String]]) -> String {
        var parts: [String] = []
        var seen = Set<String>()

        appendKeywordText(windowTitle, limit: keywordTitleLimit, to: &parts, seen: &seen)
        for scope in elementShortTexts {
            for text in scope {
                appendKeywordText(text, limit: keywordFieldLimit, to: &parts, seen: &seen)
            }
        }

        return parts.joined(separator: "\n")
    }

    static func keywordHaystack(windowTitle: String, elementNodes: [FocusRegionNode]) -> String {
        let scopes = keywordScopes(in: elementNodes)
        return keywordHaystack(windowTitle: windowTitle, elementShortTexts: scopes)
    }

    static func detectTerminalContext(
        bundleID: String? = nil,
        haystack: String,
        text: String?,
        config: ContextDetectionConfig = .default
    ) -> DetectedLang? {
        detectTerminalDecision(bundleID: bundleID, haystack: haystack, text: text, regionText: nil, config: config)?.lang
    }

    static func detectTerminalDecision(
        bundleID: String? = nil,
        haystack: String,
        text: String?,
        regionText: String?,
        config: ContextDetectionConfig = .default
    ) -> ContextDecision? {
        let line = text.map(currentLine)
        let regionTailText = regionTail(regionText)
        let regionLine = currentLine(regionTailText)
        guard isTerminalContext(bundleID: bundleID, haystack: haystack, currentLine: line, regionLine: regionLine, regionText: regionText, config: config) else { return nil }

        // 代理型 AI 工具（Claude Code / Codex / OpenCode）判定优先于 shell 提示符短路，
        // 否则 Claude Code 的 TUI 提示符（❯/$ 等）会被误判成普通 shell 而强制英文。
        // 纯终端的窗口标题反映当前前台进程，计入代理检测范围；Electron 宿主（Codex/VSCode
        // 桌面端、Claude Desktop 等）的标题只是应用外框，不得仅凭标题触发，只看屏幕正文。
        // 注意 agentScope 用 line（仅光标所在行）而非整段 text，避免历史回滚里的 "codex"
        // 误判，保留“退出 agent 回到 prompt → 英文”的语义。
        let titleIsChrome = bundleID != nil && isElectronLikeHost(bundleID, config: config)
        let agentScope = titleIsChrome
            ? [regionTailText, line ?? ""].joined(separator: "\n")
            : [haystack, regionTailText, line ?? ""].joined(separator: "\n")
        if containsTerminalAgentKeyword(agentScope, config: config) {
            return ContextDecision(kind: .terminalAgent, lang: .chinese, source: "terminal-agent")
        }

        if let line, looksLikePromptLine(line) {
            return ContextDecision(kind: .terminalShell, lang: .english, source: "terminal-prompt")
        }
        if looksLikePromptLine(regionLine) {
            return ContextDecision(kind: .terminalShell, lang: .english, source: "terminal-region-prompt")
        }
        return ContextDecision(kind: .terminalShell, lang: .english, source: "terminal-shell")
    }

    static func detectLanguage(
        cursorText: String?,
        regionText: String?,
        windowText: String?,
        windowTitle: String
    ) -> DetectedLang? {
        if let cursorText, let lang = classify(cursorText) {
            return lang
        }
        if let regionText, let lang = classify(regionText) {
            return lang
        }
        if let windowText, let lang = classify(windowText) {
            return lang
        }
        return classify(windowTitle)
    }

    static func focusRegionIndex(in nodes: [FocusRegionNode]) -> Int? {
        var textFallbackIndex: Int?

        for index in nodes.indices {
            let role = nodes[index].role
            if focusRegionWindowBoundaryRoles.contains(role) {
                return textFallbackIndex
            }
            if focusRegionChromeBoundaryRoles.contains(role) {
                return nil
            }
            if focusRegionContainerRoles.contains(role), !hasChromeParent(at: index, in: nodes) {
                return index
            }
            if textFallbackIndex == nil, focusRegionTextRoles.contains(role) {
                textFallbackIndex = index
            }
        }

        return textFallbackIndex
    }

    /// 限额遍历窗口 AX 树，收集可见文本内容（如微信聊天记录、网页正文），
    /// 跳过菜单/工具栏/按钮等界面元素，避免本地化 UI 文案干扰判定
    private static func collectWindowText(_ window: AXUIElement, meter: AXReadMeter) -> String {
        collectText(root: window, profile: .windowFallback, meter: meter)
    }

    private static func collectText(
        root: AXUIElement,
        profile: TextCollectionProfile,
        meter: AXReadMeter
    ) -> String {
        var collected = ""
        var visited = 0
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0

        while index < queue.count,
              visited < profile.nodeBudget,
              collected.count < profile.charBudget {
            let (el, depth) = queue[index]
            index += 1
            visited += 1

            // 每处理 10 个节点检查一次紧急熔断
            if visited % 10 == 0, meter.shouldAbort() {
                break
            }

            meter.add()
            guard let role = AX.copyString(el, kAXRoleAttribute as String) else { continue }
            if skipTextCollectionRoles.contains(role) { continue }
            if textRoles.contains(role) {
                meter.add()
                if let value = AX.copyStringLike(el, kAXValueAttribute as String), !value.isEmpty {
                    collected += value.prefix(300)
                    collected += "\n"
                    if collected.count >= profile.earlyClassifyAfter,
                       classify(collected) != nil {
                        break
                    }
                }
                continue
            }
            if depth < textCollectionMaxDepth {
                meter.add(AX.childrenAttributes.count)
                if let children = AX.copyChildren(el) {
                    for child in children.prefix(profile.childLimit) {
                        queue.append((child, depth + 1))
                    }
                }
            }
        }
        return collected
    }

    private static func focusRegionContext(
        from element: AXUIElement,
        meter: AXReadMeter
    ) -> FocusRegionContext {
        let chain = focusAncestorChain(from: element, meter: meter)
        let root = focusRegionIndex(in: chain.map(\.node)).map { chain[$0].element }
        return FocusRegionContext(root: root, nodes: chain.map(\.node))
    }

    private static func focusAncestorChain(
        from element: AXUIElement,
        meter: AXReadMeter
    ) -> [(element: AXUIElement, node: FocusRegionNode)] {
        var chain: [(AXUIElement, FocusRegionNode)] = []
        var current: AXUIElement? = element

        for _ in 0...focusRegionParentDepth {
            guard let node = current else { break }
            chain.append((node, focusRegionNode(from: node, meter: meter)))
            meter.add()
            current = AX.copyElement(node, kAXParentAttribute as String)
        }

        return chain
    }

    private static func focusRegionNode(from element: AXUIElement, meter: AXReadMeter) -> FocusRegionNode {
        let (values, reads) = AX.copyStringLikes(element, keywordAttributes)
        meter.add(reads)
        return FocusRegionNode(
            role: values[kAXRoleAttribute as String] ?? "",
            subrole: values[kAXSubroleAttribute as String],
            shortTexts: keywordAttributes.compactMap { values[$0] }
        )
    }

    private static func keywordScopes(in nodes: [FocusRegionNode]) -> [[String]] {
        let endIndex = focusRegionIndex(in: nodes) ?? min(keywordParentDepth, nodes.count - 1)
        guard endIndex >= 0 else { return [] }
        return nodes.prefix(endIndex + 1).map(\.shortTexts)
    }

    private static func semanticHaystack(windowTitle: String, elementNodes: [FocusRegionNode]) -> String {
        var texts: [String] = [windowTitle]
        if let focused = elementNodes.first {
            texts.append(contentsOf: focused.shortTexts)
        }
        texts.append(contentsOf: keywordScopes(in: elementNodes).flatMap { $0 })
        return texts.joined(separator: "\n")
    }

    private static func hasChromeParent(at index: Int, in nodes: [FocusRegionNode]) -> Bool {
        let parentIndex = index + 1
        guard nodes.indices.contains(parentIndex) else { return false }
        return focusRegionChromeBoundaryRoles.contains(nodes[parentIndex].role)
    }

    private static func textNearCursor(_ el: AXUIElement, meter: AXReadMeter) -> String? {
        meter.add()
        if let total = AX.copyInt(el, kAXNumberOfCharactersAttribute as String), total > 0 {
            meter.add()
            let cursor = AX.copyRange(el, kAXSelectedTextRangeAttribute as String)?.location ?? total
            let start = max(0, cursor - 300)
            let length = min(total - start, 600)
            if length > 0 {
                meter.add()
                if let text = AX.copyStringForRange(el, CFRange(location: start, length: length)),
                   !text.isEmpty {
                    return text
                }
            }
        }
        meter.add()
        if let value = AX.copyString(el, kAXValueAttribute as String), !value.isEmpty {
            return String(value.suffix(600))
        }
        return nil
    }

    private static func currentLine(_ text: String) -> String {
        if let newline = text.lastIndex(of: "\n") {
            return String(text[text.index(after: newline)...])
        }
        return text
    }

    private static func looksLikePromptLine(_ line: String) -> Bool {
        let tail = String(line.suffix(200))
        return shellPromptRegex.firstMatch(
            in: tail,
            range: NSRange(tail.startIndex..., in: tail)
        ) != nil
    }

    private static func isTerminalContext(
        bundleID: String?,
        haystack: String,
        currentLine: String?,
        regionLine: String,
        regionText: String?,
        config: ContextDetectionConfig
    ) -> Bool {
        if let bundleID, config.terminalBundleIDs.contains(bundleID) {
            return true
        }
        let lowerHaystack = haystack.lowercased()
        if terminalIdentityKeywords.contains(where: lowerHaystack.contains) {
            return true
        }
        if let regionText {
            let lowerRegion = regionTail(regionText).lowercased()
            if terminalIdentityKeywords.contains(where: lowerRegion.contains) {
                return true
            }
        }
        if let currentLine, looksLikePromptLine(currentLine) {
            if let bundleID, config.multiContextHostBundleIDs.contains(bundleID) {
                return false
            }
            return true
        }
        if bundleID == "com.openai.codex", looksLikePromptLine(regionLine) {
            return true
        }
        return false
    }

    private static func isAssistantChatContext(
        bundleID: String?,
        semanticText: String,
        haystack: String,
        hasElement: Bool,
        config: ContextDetectionConfig
    ) -> Bool {
        let lowerSemantic = semanticText.lowercased()
        if config.chatSemanticKeywords.contains(where: lowerSemantic.contains),
           !terminalIdentityKeywords.contains(where: lowerSemantic.contains) {
            return true
        }
        if let bundleID, bundleID == "com.openai.chat", hasElement {
            return true
        }
        return false
    }

    private static func hasComponentSignal(elementNodes: [FocusRegionNode], hasElement: Bool) -> Bool {
        guard hasElement, let focused = elementNodes.first else { return false }
        if focusRegionTextRoles.contains(focused.role) {
            return true
        }
        if elementNodes.contains(where: { node in
            node.shortTexts.contains { !$0.split(whereSeparator: \.isWhitespace).isEmpty }
        }) {
            return true
        }
        return elementNodes.contains { node in
            !node.role.isEmpty
                && !focusRegionWindowBoundaryRoles.contains(node.role)
                && !focusRegionContainerRoles.contains(node.role)
        }
    }

    private static func hasSecureTextField(_ nodes: [FocusRegionNode]) -> Bool {
        guard let focused = nodes.first else { return false }
        return secureTextRoles.contains(focused.role)
            || focused.subrole == "AXSecureTextField"
    }

    private static func hasVisibleText(_ text: String?) -> Bool {
        guard let text else { return false }
        return text.contains { !$0.isWhitespace }
    }

    private static func isElectronLikeHost(_ bundleID: String?, config: ContextDetectionConfig) -> Bool {
        guard let bundleID else { return false }
        return config.multiContextHostBundleIDs.contains(bundleID)
    }

    private static func regionTail(_ text: String?) -> String {
        guard let text else { return "" }
        return String(text.suffix(1000))
    }

    private static func containsTerminalAgentKeyword(_ text: String, config: ContextDetectionConfig) -> Bool {
        let lower = text.lowercased()
        return config.terminalAgentKeywords.contains { lower.contains($0) }
    }

    private static func appendKeywordText(_ text: String, limit: Int, to parts: inout [String], seen: inout Set<String>) {
        let compact = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !compact.isEmpty else { return }

        let short = String(compact.prefix(limit))
        guard seen.insert(short).inserted else { return }
        parts.append(short)
    }

    /// 汉字占比启发式 + NLLanguageRecognizer 兜底
    static func classify(_ text: String) -> DetectedLang? {
        LanguageClassifier.classify(text)
    }

    /// 汉字占比启发式 + NLLanguageRecognizer 兜底
    static func classifyDetailed(_ text: String) -> LanguageClassification? {
        LanguageClassifier.classifyDetailed(text)
    }
}
