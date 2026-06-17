import ApplicationServices
import CryptoKit
import Foundation

/// 组件指纹生成器。
///
/// 设计目标：让"同一种输入组件"在同一次会话、甚至跨多次聚焦时得到**稳定且可通用化**的指纹，
/// 使得用户的手动中/英文纠正能被记住并复用。
///
/// 指纹只由**稳定且语义化**的信号构成：
///   `bundle + 焦点元素 role/subrole + 最近的语义标签文本(placeholder/title/description/help)`
///
/// 刻意**不**使用以下高频抖动信号（它们会导致"每次指纹都变、永远学不会"）：
///   - 祖先深度 `at=<index>`（插删一层 wrapper 就变）
///   - 祖先结构链 `chain=<前N层 role>`（动态 Web UI 频繁变化）
///   - `AXIdentifier` / `AXDOMIdentifier`（网页里常是 React/MUI 自动生成，每次重渲染都变）
///
/// 通用化粒度：同一 App 内 role+subrole+label 相同的输入框共用一条学习记录。
enum SmartLearningKeyBuilder {
    static let version = "smart-component:v3"
    private static let maxTextLength = 120
    /// 向上查找语义标签的最大层数（标签常挂在焦点元素本身或其近祖容器上）
    private static let labelAncestorDepth = 8

    struct Node: Equatable {
        var role: String
        var subrole: String?
        var identifier: String?
        var domIdentifier: String?
        var title: String?
        var description: String?
        var placeholder: String?
        var help: String?

        init(
            role: String,
            subrole: String? = nil,
            identifier: String? = nil,
            domIdentifier: String? = nil,
            title: String? = nil,
            description: String? = nil,
            placeholder: String? = nil,
            help: String? = nil
        ) {
            self.role = role
            self.subrole = subrole
            self.identifier = identifier
            self.domIdentifier = domIdentifier
            self.title = title
            self.description = description
            self.placeholder = placeholder
            self.help = help
        }
    }

    static func key(bundleID: String, element: AXUIElement?, contextKind: ContextKind = .unknown) -> SmartLearningKey? {
        guard let element else {
            return fallbackKey(bundleID: bundleID, contextKind: contextKind)
        }
        return key(bundleID: bundleID, nodes: nodes(from: element), contextKind: contextKind)
    }

    static func key(bundleID: String, nodes: [Node], contextKind: ContextKind = .unknown) -> SmartLearningKey? {
        guard !bundleID.isEmpty, let anchor = componentAnchor(nodes: nodes) else { return nil }
        let canonical = "\(version)|bundle=\(normalize(bundleID))|context=\(contextKind.rawValue)|\(anchor)"
        return SmartLearningKey(rawValue: digest(canonical))
    }

    static func nodes(from element: AXUIElement) -> [Node] {
        var nodes: [Node] = []
        var current: AXUIElement? = element

        for _ in 0...12 {
            guard let currentNode = current else { break }
            nodes.append(Node(
                role: AX.copyString(currentNode, kAXRoleAttribute as String) ?? "",
                subrole: AX.copyString(currentNode, kAXSubroleAttribute as String),
                identifier: AX.copyStringLike(currentNode, "AXIdentifier"),
                domIdentifier: AX.copyStringLike(currentNode, "AXDOMIdentifier"),
                title: AX.copyStringLike(currentNode, kAXTitleAttribute as String),
                description: AX.copyStringLike(currentNode, kAXDescriptionAttribute as String),
                placeholder: AX.copyStringLike(currentNode, "AXPlaceholderValue"),
                help: AX.copyStringLike(currentNode, kAXHelpAttribute as String)
            ))
            current = AX.copyElement(currentNode, kAXParentAttribute as String)
        }

        return nodes
    }

    /// 调试用：把参与指纹计算的输入与结果描述成一行可读文本，便于在 Console.app 核对稳定性。
    static func trace(bundleID: String, element: AXUIElement?, contextKind: ContextKind = .unknown) -> String {
        trace(bundleID: bundleID, nodes: element.map { nodes(from: $0) } ?? [], contextKind: contextKind)
    }

    /// 调试用：把参与指纹计算的输入与结果描述成一行可读文本，便于在 Console.app 核对稳定性。
    static func trace(bundleID: String, nodes: [Node], contextKind: ContextKind = .unknown) -> String {
        let normalizedNodes = nodes.map(normalized)
        let focused = normalizedNodes.first
        let role = focused?.role ?? ""
        let subrole = focused?.subrole ?? ""
        let label = nearestLabel(in: normalizedNodes) ?? ""
        let ancestorRoles = normalizedNodes.dropFirst().prefix(labelAncestorDepth)
            .map(\.role)
            .joined(separator: ">")
        let key = key(bundleID: bundleID, nodes: nodes, contextKind: contextKind)?.rawValue ?? "nil"
        let keyTag = String(key.prefix(20))
        return "bundle=\(bundleID) context=\(contextKind.rawValue) role=\(role) subrole=\(subrole) label=\"\(label)\" ancestors=\(ancestorRoles) key=\(keyTag)"
    }

    /// 锚点：焦点元素 role/subrole + 最近的语义标签。
    /// 只要焦点元素有 role（几乎总有），就产出指纹（即便无标签也按 role 通用化）。
    private static func componentAnchor(nodes: [Node]) -> String? {
        let normalizedNodes = nodes.map(normalized)
        guard let focused = normalizedNodes.first, !focused.role.isEmpty else { return nil }
        let label = nearestLabel(in: normalizedNodes) ?? ""
        return "role=\(focused.role)|subrole=\(focused.subrole ?? "")|label=\(label)"
    }

    /// 从焦点元素向上查找最近的语义标签（placeholder 最优先，其次 title/aria-label、description、help）。
    /// 只取标签**文本**，不带入深度或祖先结构，保证稳定性。
    private static func nearestLabel(in nodes: [Node]) -> String? {
        for node in nodes.prefix(labelAncestorDepth) {
            if let label = firstNonEmpty(node.placeholder, node.title, node.description, node.help) {
                return label
            }
        }
        return nil
    }

    private static func normalized(_ node: Node) -> Node {
        Node(
            role: normalize(node.role),
            subrole: normalizeOptional(node.subrole),
            identifier: normalizeOptional(node.identifier),
            domIdentifier: normalizeOptional(node.domIdentifier),
            title: normalizeOptional(node.title),
            description: normalizeOptional(node.description),
            placeholder: normalizeOptional(node.placeholder),
            help: normalizeOptional(node.help)
        )
    }

    private static func normalizeOptional(_ text: String?) -> String? {
        guard let normalized = text.map(normalize), !normalized.isEmpty else { return nil }
        return normalized
    }

    private static func normalize(_ text: String) -> String {
        let compact = text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
        return String(compact.prefix(maxTextLength))
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values.first { value in
            guard let value else { return false }
            return !value.isEmpty
        } ?? nil
    }

    private static func digest(_ text: String) -> String {
        let hash = SHA256.hash(data: Data(text.utf8))
        return version + ":" + hash.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func fallbackKey(bundleID: String, contextKind: ContextKind) -> SmartLearningKey? {
        guard !bundleID.isEmpty, contextKind != .unknown else { return nil }
        let canonical = "\(version)|bundle=\(normalize(bundleID))|context=\(contextKind.rawValue)|fallback=no-focused-element"
        return SmartLearningKey(rawValue: digest(canonical))
    }
}
