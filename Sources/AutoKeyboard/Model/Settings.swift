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

struct AppSettings: Codable {
    var enabled = true
    var englishSourceID: String?
    var chineseSourceID: String?
    var defaultMode: AppMode = .memory
    var smartLearningEnabled = true
    var ocrAssistedDetection = false
    var appRules: [AppRule] = []

    init(
        enabled: Bool = true,
        englishSourceID: String? = nil,
        chineseSourceID: String? = nil,
        defaultMode: AppMode = .memory,
        smartLearningEnabled: Bool = true,
        ocrAssistedDetection: Bool = false,
        appRules: [AppRule] = []
    ) {
        self.enabled = enabled
        self.englishSourceID = englishSourceID
        self.chineseSourceID = chineseSourceID
        self.defaultMode = defaultMode
        self.smartLearningEnabled = smartLearningEnabled
        self.ocrAssistedDetection = ocrAssistedDetection
        self.appRules = appRules
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case englishSourceID
        case chineseSourceID
        case defaultMode
        case smartLearningEnabled
        case ocrAssistedDetection
        case appRules
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        englishSourceID = try container.decodeIfPresent(String.self, forKey: .englishSourceID)
        chineseSourceID = try container.decodeIfPresent(String.self, forKey: .chineseSourceID)
        defaultMode = try container.decodeIfPresent(AppMode.self, forKey: .defaultMode) ?? .memory
        smartLearningEnabled = try container.decodeIfPresent(Bool.self, forKey: .smartLearningEnabled) ?? true
        ocrAssistedDetection = try container.decodeIfPresent(Bool.self, forKey: .ocrAssistedDetection) ?? false
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
