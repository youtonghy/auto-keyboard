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
    var appRules: [AppRule] = []
}

@MainActor
final class SettingsStore: ObservableObject {
    private static let key = "settings.v1"

    @Published var value: AppSettings {
        didSet {
            save()
            onChange?()
        }
    }

    var onChange: (() -> Void)?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
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
        UserDefaults.standard.set(data, forKey: Self.key)
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
