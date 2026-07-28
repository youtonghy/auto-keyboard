import Foundation

enum LangChoice: String, Codable, CaseIterable, Hashable {
    case english
    case chinese

    var label: String {
        switch self {
        case .english: "英文"
        case .chinese: "中文"
        }
    }
}

enum AppMode: String, Codable, CaseIterable, Hashable {
    case memory
    case forceEnglish
    case forceChinese
    case smart

    var label: String {
        switch self {
        case .memory: "窗口记忆"
        case .forceEnglish: "强制英文"
        case .forceChinese: "强制中文"
        case .smart: "智能上下文"
        }
    }
}

struct KeywordRule: Codable, Identifiable, Hashable {
    var id = UUID()
    var keyword: String = ""
    var lang: LangChoice = .chinese
}

struct AppRule: Codable, Identifiable, Hashable {
    var id = UUID()
    var bundleID: String
    var displayName: String
    var mode: AppMode = .memory
    var defaultLang: LangChoice?
    var keywordRules: [KeywordRule] = []
}

struct SmartContextSettings: Codable, Hashable {
    var terminalBundleIDs: [String]
    var multiContextHostBundleIDs: [String]
    var terminalAgentKeywords: [String]
    var chatSemanticKeywords: [String]

    init(
        terminalBundleIDs: [String] = Self.defaultTerminalBundleIDs,
        multiContextHostBundleIDs: [String] = Self.defaultMultiContextHostBundleIDs,
        terminalAgentKeywords: [String] = Self.defaultTerminalAgentKeywords,
        chatSemanticKeywords: [String] = Self.defaultChatSemanticKeywords
    ) {
        self.terminalBundleIDs = terminalBundleIDs
        self.multiContextHostBundleIDs = multiContextHostBundleIDs
        self.terminalAgentKeywords = terminalAgentKeywords
        self.chatSemanticKeywords = chatSemanticKeywords
    }

    static let defaultTerminalBundleIDs = [
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

    static let defaultMultiContextHostBundleIDs = [
        "com.openai.codex",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.visualstudio.code.oss",
        "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf",
        "ai.opencode.desktop",
        "com.anthropic.claudefordesktop",
    ]

    static let defaultTerminalAgentKeywords = [
        "codex",
        "claude code",
        "claude-code",
        "claude",
        "opencode",
        "open code",
    ]

    static let defaultChatSemanticKeywords = [
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
}

/// 智能模式负载保护阈值。
///
/// 极复杂页面上一次 AX 快照可能发出上千次跨进程读取、占用主线程数百毫秒；
/// 若每次击键都这样读一遍，系统会明显卡顿。这里定义"多贵算太贵"以及连续多少次
/// 之后放弃对该应用使用智能模式。
struct SmartLoadGuardSettings: Codable, Hashable {
    /// 单次快照允许的 AX 跨进程读取次数上限。
    var maxAXReads: Int
    /// 单次快照允许占用主线程的秒数上限。
    var maxElapsedSeconds: TimeInterval
    /// 连续超限多少次后暂停该应用的智能模式。
    var overloadStrikes: Int
    /// 暂停后多久放行一次完整采样试探（秒）。
    var recheckInterval: TimeInterval
    var enabled: Bool

    init(
        maxAXReads: Int = 700,
        maxElapsedSeconds: TimeInterval = 0.6,
        overloadStrikes: Int = 3,
        recheckInterval: TimeInterval = 600,
        enabled: Bool = true
    ) {
        self.maxAXReads = maxAXReads
        self.maxElapsedSeconds = maxElapsedSeconds
        self.overloadStrikes = overloadStrikes
        self.recheckInterval = recheckInterval
        self.enabled = enabled
    }
}

struct AppSettings: Codable {
    var enabled = true
    var englishSourceID: String?
    var chineseSourceID: String?
    var defaultMode: AppMode = .memory
    var smartLearningEnabled = true
    var smartContext = SmartContextSettings()
    var smartLoadGuard = SmartLoadGuardSettings()
    var appRules: [AppRule] = []

    init(
        enabled: Bool = true,
        englishSourceID: String? = nil,
        chineseSourceID: String? = nil,
        defaultMode: AppMode = .memory,
        smartLearningEnabled: Bool = true,
        smartContext: SmartContextSettings = SmartContextSettings(),
        smartLoadGuard: SmartLoadGuardSettings = SmartLoadGuardSettings(),
        appRules: [AppRule] = []
    ) {
        self.enabled = enabled
        self.englishSourceID = englishSourceID
        self.chineseSourceID = chineseSourceID
        self.defaultMode = defaultMode
        self.smartLearningEnabled = smartLearningEnabled
        self.smartContext = smartContext
        self.smartLoadGuard = smartLoadGuard
        self.appRules = appRules
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case englishSourceID
        case chineseSourceID
        case defaultMode
        case smartLearningEnabled
        case smartContext
        case smartLoadGuard
        case appRules
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        englishSourceID = try container.decodeIfPresent(String.self, forKey: .englishSourceID)
        chineseSourceID = try container.decodeIfPresent(String.self, forKey: .chineseSourceID)
        defaultMode = try container.decodeIfPresent(AppMode.self, forKey: .defaultMode) ?? .memory
        smartLearningEnabled = try container.decodeIfPresent(Bool.self, forKey: .smartLearningEnabled) ?? true
        smartContext = try container.decodeIfPresent(SmartContextSettings.self, forKey: .smartContext) ?? SmartContextSettings()
        smartLoadGuard = try container.decodeIfPresent(SmartLoadGuardSettings.self, forKey: .smartLoadGuard) ?? SmartLoadGuardSettings()
        appRules = try container.decodeIfPresent([AppRule].self, forKey: .appRules) ?? []
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    private static let key = "settings.v1"
    private let defaults: UserDefaults
    private let storageKey: String

    @Published var value: AppSettings {
        didSet {
            save()
            onChange?()
        }
    }

    var onChange: (() -> Void)?

    init(defaults: UserDefaults = .standard, key: String = SettingsStore.key) {
        self.defaults = defaults
        self.storageKey = key
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            value = decoded
        } else {
            value = Self.firstRunDefaults()
        }
    }

    func rule(for bundleID: String) -> AppRule? {
        value.appRules.first { $0.bundleID == bundleID }
    }

    func upsertRule(_ rule: AppRule) {
        if let idx = value.appRules.firstIndex(where: { $0.bundleID == rule.bundleID }) {
            value.appRules[idx] = rule
        } else {
            value.appRules.append(rule)
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private static func firstRunDefaults() -> AppSettings {
        let agentKeywords = [
            KeywordRule(keyword: "claude", lang: .chinese),
            KeywordRule(keyword: "codex", lang: .chinese),
        ]
        return AppSettings(appRules: [
            AppRule(bundleID: "com.apple.Terminal", displayName: "终端",
                    mode: .memory, defaultLang: .english, keywordRules: agentKeywords),
            AppRule(bundleID: "com.googlecode.iterm2", displayName: "iTerm2",
                    mode: .memory, defaultLang: .english, keywordRules: agentKeywords),
        ])
    }
}
