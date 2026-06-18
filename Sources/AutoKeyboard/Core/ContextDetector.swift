import ApplicationServices
import Foundation
import NaturalLanguage

enum DetectedLang: Equatable {
    case chinese
    case english
}

enum ContextKind: String, Hashable {
    case assistantChatInput
    case terminalShell
    case terminalAgent
    case normalTextInput
    case ocrContext
    case unknown
}

enum AXCapability: String, Hashable {
    case componentVisible
    case textVisibleStrong
    case textVisibleWeak
    case blackBox

    var label: String {
        switch self {
        case .componentVisible:
            "AX 智能可用"
        case .textVisibleStrong:
            "AX 可读，允许智能识别"
        case .textVisibleWeak:
            "AX 弱可读，优先 OCR"
        case .blackBox:
            "AX 黑盒，无法定位具体输入组件"
        }
    }

    var allowsAXDetection: Bool {
        self == .componentVisible || self == .textVisibleStrong
    }

    var prefersOCRInSmartMode: Bool {
        self == .textVisibleWeak || self == .blackBox
    }
}

struct ContextDecision: Equatable {
    let kind: ContextKind
    let lang: DetectedLang?
    let source: String
}

@MainActor
enum ContextDetector {
    private static let keywordFieldLimit = 180
    private static let keywordTitleLimit = 500
    private static let keywordParentDepth = 4
    private static let focusRegionParentDepth = 12
    private static let textCollectionCharBudget = 1500
    private static let textCollectionNodeBudget = 300
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
    private static let terminalAgentKeywords = [
        "codex",
        "claude code",
        "claude-code",
        "claude",
        "opencode",
        "open code",
    ]
    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "org.alacritty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
        "org.tabby",
    ]
    private static let multiContextHostBundleIDs: Set<String> = [
        "com.openai.codex",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.visualstudio.code.oss",
        "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf",
    ]
    private static let shellPromptRegex = try! NSRegularExpression(
        pattern: #"(?:^|\s)(?:[➜→❯»$%#]|PS[^\n]*>)\s*$"#
    )
    private static let chatSemanticKeywords = [
        "message",
        "chat",
        "prompt",
        "ask",
        "compose",
        "reply",
        "输入",
        "消息",
        "聊天",
        "提问",
        "发送",
    ]
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

    /// 智能上下文判定：输入语义 → 输入正文 → 焦点区域正文 → 窗口可见内容 → 窗口标题
    static func detect(bundleID: String? = nil, element: AXUIElement?, window: AXUIElement?, windowTitle: String) -> DetectedLang? {
        detectDecision(bundleID: bundleID, element: element, window: window, windowTitle: windowTitle)?.lang
    }

    static func detectDecision(bundleID: String? = nil, element: AXUIElement?, window: AXUIElement?, windowTitle: String) -> ContextDecision? {
        let cursorText = element.flatMap(textNearCursor)
        let focusContext = element.map(focusRegionContext)
        let nodes = focusContext?.nodes ?? []
        return detectDecision(
            bundleID: bundleID,
            windowTitle: windowTitle,
            elementNodes: nodes,
            cursorText: cursorText,
            regionText: focusContext?.root.map(collectText(root:)),
            windowText: window.map(collectWindowText),
            hasElement: element != nil
        )
    }

    static func axCapability(bundleID: String? = nil, element: AXUIElement?, window: AXUIElement?) -> AXCapability {
        let cursorText = element.flatMap(textNearCursor)
        let focusContext = element.map(focusRegionContext)
        return axCapability(
            bundleID: bundleID,
            elementNodes: focusContext?.nodes ?? [],
            cursorText: cursorText,
            regionText: focusContext?.root.map(collectText(root:)),
            windowText: window.map(collectWindowText),
            hasElement: element != nil
        )
    }

    static func axCapability(
        bundleID: String? = nil,
        elementNodes: [FocusRegionNode],
        cursorText: String?,
        regionText: String?,
        windowText: String?,
        hasElement: Bool
    ) -> AXCapability {
        let electronLike = isElectronLikeHost(bundleID)
        if hasComponentSignal(elementNodes: elementNodes, hasElement: hasElement) {
            return .componentVisible
        }
        if hasVisibleText(cursorText) || hasVisibleText(regionText) {
            return .textVisibleStrong
        }
        if electronLike, hasVisibleText(windowText) {
            return .textVisibleWeak
        }
        if electronLike {
            return .blackBox
        }
        if hasVisibleText(windowText) {
            return .textVisibleStrong
        }
        return .blackBox
    }

    static func detectDecision(
        bundleID: String? = nil,
        windowTitle: String,
        elementNodes: [FocusRegionNode],
        cursorText: String?,
        regionText: String?,
        windowText: String? = nil,
        hasElement: Bool = true
    ) -> ContextDecision? {
        let haystack = keywordHaystack(windowTitle: windowTitle, elementNodes: elementNodes)
        let semanticText = semanticHaystack(windowTitle: windowTitle, elementNodes: elementNodes)
        let terminalDecision = detectTerminalDecision(
            bundleID: bundleID,
            haystack: haystack,
            text: cursorText,
            regionText: regionText ?? windowText
        )
        if let terminalDecision {
            return terminalDecision
        }
        if isAssistantChatContext(bundleID: bundleID, semanticText: semanticText, haystack: haystack, hasElement: hasElement) {
            return ContextDecision(kind: .assistantChatInput, lang: .chinese, source: "assistant-chat")
        }
        if let cursorText, let lang = classify(cursorText) {
            return ContextDecision(kind: .normalTextInput, lang: lang, source: "cursor-text")
        }
        if let regionText, let lang = classify(regionText) {
            return ContextDecision(kind: .normalTextInput, lang: lang, source: "focus-region")
        }
        if let windowText, let lang = classify(windowText) {
            return ContextDecision(kind: .normalTextInput, lang: lang, source: "window-text")
        }
        if (hasElement || !isElectronLikeHost(bundleID)), let lang = classify(windowTitle) {
            return ContextDecision(kind: .normalTextInput, lang: lang, source: "window-title")
        }
        return nil
    }

    static func detectTerminal(bundleID: String?, element: AXUIElement?, windowTitle: String) -> DetectedLang? {
        detectTerminalDecision(bundleID: bundleID, element: element, windowTitle: windowTitle)?.lang
    }

    static func detectTerminalDecision(bundleID: String?, element: AXUIElement?, windowTitle: String) -> ContextDecision? {
        let cursorText = element.flatMap(textNearCursor)
        let focusContext = element.map(focusRegionContext)
        let nodes = focusContext?.nodes ?? []
        return detectTerminalDecision(
            bundleID: bundleID,
            haystack: keywordHaystack(windowTitle: windowTitle, elementNodes: nodes),
            text: cursorText,
            regionText: focusContext?.root.map(collectText(root:))
        )
    }

    /// 上下文关键词匹配文本：窗口标题 → 当前焦点元素短属性 → 父级区域短属性。
    /// 只收集短元数据，避免把整段代码、终端输出或聊天正文当成关键词来源。
    static func keywordHaystack(element: AXUIElement?, windowTitle: String) -> String {
        keywordHaystack(
            windowTitle: windowTitle,
            elementNodes: element.map(focusRegionContext)?.nodes ?? []
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

    static func detectTerminalContext(bundleID: String? = nil, haystack: String, text: String?) -> DetectedLang? {
        detectTerminalDecision(bundleID: bundleID, haystack: haystack, text: text, regionText: nil)?.lang
    }

    static func detectTerminalDecision(
        bundleID: String? = nil,
        haystack: String,
        text: String?,
        regionText: String?
    ) -> ContextDecision? {
        let line = text.map(currentLine)
        let regionTailText = regionTail(regionText)
        let regionLine = currentLine(regionTailText)
        guard isTerminalContext(bundleID: bundleID, haystack: haystack, currentLine: line, regionLine: regionLine, regionText: regionText) else { return nil }

        let titleIsChrome = bundleID != nil && isElectronLikeHost(bundleID)
        let agentScope = titleIsChrome
            ? [regionTailText, line ?? ""].joined(separator: "\n")
            : [haystack, regionTailText, line ?? ""].joined(separator: "\n")
        if containsTerminalAgentKeyword(agentScope) {
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

    /// OCR 兜底判定：对屏幕识别到的「光标附近」文本复用汉字占比分类器。
    /// 文本不足（classify 返回 nil）则返回 nil，不切换。
    static func ocrDecision(text: String) -> ContextDecision? {
        guard let lang = classify(text) else { return nil }
        return ContextDecision(kind: .ocrContext, lang: lang, source: "ocr")
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
    private static func collectWindowText(_ window: AXUIElement) -> String {
        collectText(root: window)
    }

    private static func collectText(root: AXUIElement) -> String {
        var collected = ""
        var visited = 0
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0

        while index < queue.count,
              visited < textCollectionNodeBudget,
              collected.count < textCollectionCharBudget {
            let (el, depth) = queue[index]
            index += 1
            visited += 1
            guard let role = AX.copyString(el, kAXRoleAttribute as String) else { continue }
            if skipTextCollectionRoles.contains(role) { continue }
            if textRoles.contains(role) {
                if let value = AX.copyStringLike(el, kAXValueAttribute as String), !value.isEmpty {
                    collected += value.prefix(300)
                    collected += "\n"
                }
                continue
            }
            if depth < textCollectionMaxDepth, let children = AX.copyChildren(el) {
                for child in children.prefix(50) {
                    queue.append((child, depth + 1))
                }
            }
        }
        return collected
    }

    private static func focusRegionContext(from element: AXUIElement) -> FocusRegionContext {
        let chain = focusAncestorChain(from: element)
        let root = focusRegionIndex(in: chain.map(\.node)).map { chain[$0].element }
        return FocusRegionContext(root: root, nodes: chain.map(\.node))
    }

    private static func focusAncestorChain(
        from element: AXUIElement
    ) -> [(element: AXUIElement, node: FocusRegionNode)] {
        var chain: [(AXUIElement, FocusRegionNode)] = []
        var current: AXUIElement? = element

        for _ in 0...focusRegionParentDepth {
            guard let node = current else { break }
            chain.append((node, focusRegionNode(from: node)))
            current = AX.copyElement(node, kAXParentAttribute as String)
        }

        return chain
    }

    private static func focusRegionNode(from element: AXUIElement) -> FocusRegionNode {
        FocusRegionNode(
            role: AX.copyString(element, kAXRoleAttribute as String) ?? "",
            subrole: AX.copyString(element, kAXSubroleAttribute as String),
            shortTexts: keywordAttributes.compactMap {
                AX.copyStringLike(element, $0)
            }
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

    private static func textNearCursor(_ el: AXUIElement) -> String? {
        if let total = AX.copyInt(el, kAXNumberOfCharactersAttribute as String), total > 0 {
            let cursor = AX.copyRange(el, kAXSelectedTextRangeAttribute as String)?.location ?? total
            let start = max(0, cursor - 300)
            let length = min(total - start, 600)
            if length > 0,
               let text = AX.copyStringForRange(el, CFRange(location: start, length: length)),
               !text.isEmpty {
                return text
            }
        }
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

    private static func isTerminalContext(bundleID: String?, haystack: String, currentLine: String?, regionLine: String, regionText: String?) -> Bool {
        if let bundleID, terminalBundleIDs.contains(bundleID) {
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
            if let bundleID, multiContextHostBundleIDs.contains(bundleID) {
                return false
            }
            return true
        }
        if bundleID == "com.openai.codex", looksLikePromptLine(regionLine) {
            return true
        }
        return false
    }

    private static func isAssistantChatContext(bundleID: String?, semanticText: String, haystack: String, hasElement: Bool) -> Bool {
        let lowerSemantic = semanticText.lowercased()
        if chatSemanticKeywords.contains(where: lowerSemantic.contains),
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

    private static func hasVisibleText(_ text: String?) -> Bool {
        guard let text else { return false }
        return text.contains { !$0.isWhitespace }
    }

    private static func isElectronLikeHost(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return multiContextHostBundleIDs.contains(bundleID)
            || bundleID == "com.openai.codex"
            || bundleID == "ai.opencode.desktop"
            || bundleID == "com.anthropic.claudefordesktop"
    }

    static func isClickInputCandidate(element: AXUIElement?) -> Bool? {
        guard let element else { return nil }
        let role = AX.copyString(element, kAXRoleAttribute as String) ?? ""
        let subrole = AX.copyString(element, kAXSubroleAttribute as String) ?? ""
        return isClickInputCandidate(role: role, subrole: subrole)
    }

    static func isClickInputCandidate(role: String, subrole: String? = nil) -> Bool? {
        let lowerRole = role.lowercased()
        let lowerSubrole = subrole?.lowercased() ?? ""

        if focusRegionTextRoles.contains(role) {
            return true
        }
        if lowerRole.contains("textfield")
            || lowerRole.contains("textarea")
            || lowerRole.contains("searchfield")
            || lowerRole.contains("combo")
            || lowerRole.contains("editor")
            || lowerSubrole.contains("textfield")
        {
            return true
        }
        if lowerRole.contains("button")
            || lowerRole.contains("menu")
            || lowerRole.contains("toolbar")
            || lowerRole.contains("checkbox")
            || lowerRole.contains("radio")
            || lowerRole.contains("link")
            || lowerRole.contains("tab")
            || lowerRole.contains("popup")
            || lowerRole.contains("slider")
            || lowerRole.contains("stepper")
            || lowerRole.contains("splitter")
            || lowerRole.contains("scrollbar")
        {
            return false
        }
        return nil
    }

    private static func regionTail(_ text: String?) -> String {
        guard let text else { return "" }
        return String(text.suffix(1000))
    }

    private static func containsTerminalAgentKeyword(_ text: String) -> Bool {
        let lower = text.lowercased()
        return terminalAgentKeywords.contains { lower.contains($0) }
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
        var han = 0
        var latin = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF:
                han += 1
            case 0x3001, 0x3002, 0xFF0C, 0xFF1B, 0xFF1A, 0xFF1F, 0xFF01:
                han += 1 // 中文标点
            case 0x41...0x5A, 0x61...0x7A:
                latin += 1
            default:
                break
            }
        }
        let total = han + latin
        guard total >= 2 else { return nil }
        let ratio = Double(han) / Double(total)
        if ratio >= 0.10 { return .chinese }
        if han == 0 {
            return .english
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.suffix(400)))
        switch recognizer.dominantLanguage {
        case .simplifiedChinese, .traditionalChinese:
            return .chinese
        case .some:
            return .english
        case nil:
            return nil
        }
    }
}
