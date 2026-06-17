import Foundation

struct SmartLearningKey: RawRepresentable, Hashable, Codable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }
}

@MainActor
protocol SmartLearningStoring: AnyObject {
    var count: Int { get }
    func lookup(_ key: SmartLearningKey) -> LangChoice?
    func record(_ key: SmartLearningKey, lang: LangChoice)
    func clear()
}

@MainActor
final class SmartLearningStore: ObservableObject, SmartLearningStoring {
    private struct Entry: Codable {
        var lang: LangChoice
        var updatedAt: Date
    }

    private let defaults: UserDefaults
    private let key: String
    private let capacity: Int
    private var entries: [String: Entry]

    @Published private(set) var count: Int = 0

    init(
        defaults: UserDefaults = .standard,
        key: String = "smartLearning.v1",
        capacity: Int = 500
    ) {
        self.defaults = defaults
        self.key = key
        self.capacity = capacity
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded.filter { $0.key.hasPrefix(SmartLearningKeyBuilder.version + ":") }
        } else {
            entries = [:]
        }
        trimToCapacity()
        count = entries.count
    }

    func lookup(_ key: SmartLearningKey) -> LangChoice? {
        entries[key.rawValue]?.lang
    }

    func record(_ key: SmartLearningKey, lang: LangChoice) {
        entries[key.rawValue] = Entry(lang: lang, updatedAt: Date())
        trimToCapacity()
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    private func trimToCapacity() {
        guard entries.count > capacity else { return }
        let overflow = entries.count - capacity
        let evictedKeys = entries
            .sorted { $0.value.updatedAt < $1.value.updatedAt }
            .prefix(overflow)
            .map(\.key)
        for key in evictedKeys {
            entries[key] = nil
        }
    }

    private func save() {
        count = entries.count
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
    }
}
