import ApplicationServices
import NaturalLanguage

enum DetectedLang {
    case chinese
    case english
}

@MainActor
enum ContextDetector {
    /// 智能上下文判定：焦点元素光标附近文本 → 窗口可见内容（聊天记录/页面正文）→ 窗口标题
    static func detect(element: AXUIElement?, window: AXUIElement?, windowTitle: String) -> DetectedLang? {
        if let element, let text = textNearCursor(element), let lang = classify(text) {
            return lang
        }
        if let window, let lang = classify(collectWindowText(window)) {
            return lang
        }
        return classify(windowTitle)
    }

    /// 限额遍历窗口 AX 树，收集可见文本内容（如微信聊天记录、网页正文），
    /// 跳过菜单/工具栏/按钮等界面元素，避免本地化 UI 文案干扰判定
    private static func collectWindowText(_ window: AXUIElement) -> String {
        let textRoles: Set<String> = [
            kAXStaticTextRole, kAXTextAreaRole, kAXTextFieldRole,
        ]
        let skipRoles: Set<String> = [
            kAXMenuBarRole, kAXMenuRole, kAXMenuItemRole, kAXToolbarRole,
            kAXButtonRole, kAXPopUpButtonRole, kAXMenuButtonRole,
            kAXScrollBarRole,
        ]
        let charBudget = 1500
        let nodeBudget = 300
        let maxDepth = 15

        var collected = ""
        var visited = 0
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var index = 0

        while index < queue.count, visited < nodeBudget, collected.count < charBudget {
            let (el, depth) = queue[index]
            index += 1
            visited += 1
            guard let role = AX.copyString(el, kAXRoleAttribute as String) else { continue }
            if skipRoles.contains(role) { continue }
            if textRoles.contains(role) {
                if let value = AX.copyString(el, kAXValueAttribute as String), !value.isEmpty {
                    collected += value.prefix(300)
                    collected += "\n"
                }
                continue
            }
            if depth < maxDepth, let children = AX.copyChildren(el) {
                for child in children.prefix(50) {
                    queue.append((child, depth + 1))
                }
            }
        }
        return collected
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
