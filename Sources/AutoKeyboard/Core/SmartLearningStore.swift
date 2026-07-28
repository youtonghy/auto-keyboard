import Foundation
import os

struct SmartLearningKey: RawRepresentable, Hashable, Codable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }
}

struct SmartLearningMatch: Equatable {
    let key: SmartLearningKey
    let lang: LangChoice
    let confidence: Double
    let source: String
}

@MainActor
protocol SmartLearningStoring: AnyObject {
    var count: Int { get }
    func lookup(_ keys: SmartLearningKeyBuilder.Keys) -> SmartLearningMatch?
    func recordManualCorrection(_ keys: SmartLearningKeyBuilder.Keys, lang: LangChoice)
    func recordNegativeFeedback(_ keys: SmartLearningKeyBuilder.Keys, against lang: LangChoice)
    func reinforce(_ keys: SmartLearningKeyBuilder.Keys, lang: LangChoice)
    func clear()
}

@MainActor
final class SmartLearningStore: ObservableObject, SmartLearningStoring {
    private struct StorageEnvelope: Codable {
        var schemaVersion: Int
        var activeKeyVersion: String
        var entries: [String: Entry]
        var archivedEntries: [String: Entry]
    }

    private struct Entry: Codable {
        var englishVotes: Int
        var chineseVotes: Int
        var negativeEnglishVotes: Int
        var negativeChineseVotes: Int
        var updatedAt: Date

        func negativeVotes(against lang: LangChoice) -> Int {
            switch lang {
            case .english: negativeEnglishVotes
            case .chinese: negativeChineseVotes
            }
        }

        mutating func addPositive(_ lang: LangChoice, weight: Int) {
            switch lang {
            case .english: englishVotes += weight
            case .chinese: chineseVotes += weight
            }
            updatedAt = Date()
        }

        mutating func addNegative(against lang: LangChoice) {
            switch lang {
            case .english: negativeEnglishVotes += 1
            case .chinese: negativeChineseVotes += 1
            }
            updatedAt = Date()
        }
    }

    private let defaults: UserDefaults
    private let key: String
    private let capacity: Int
    private var entries: [String: Entry]
    private var archivedEntries: [String: Entry]
    private let logger = Logger(subsystem: "com.autokeyboard", category: "learning")

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
           let envelope = try? JSONDecoder().decode(StorageEnvelope.self, from: data) {
            entries = envelope.entries.filter { $0.key.hasPrefix(SmartLearningKeyBuilder.version + ":") }
            archivedEntries = envelope.archivedEntries
            for (key, entry) in envelope.entries where !key.hasPrefix(SmartLearningKeyBuilder.version + ":") {
                archivedEntries[key] = entry
            }
        } else if let data = defaults.data(forKey: key),
                  let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded.filter { $0.key.hasPrefix(SmartLearningKeyBuilder.version + ":") }
            archivedEntries = decoded.filter { !$0.key.hasPrefix(SmartLearningKeyBuilder.version + ":") }
        } else {
            entries = [:]
            archivedEntries = [:]
        }
        trimToCapacity()
        count = entries.count
    }

    func lookup(_ keys: SmartLearningKeyBuilder.Keys) -> SmartLearningMatch? {
        for candidate in keys.lookupCandidates {
            guard let entry = entries[candidate.key.rawValue],
                  let match = match(for: candidate.key, entry: entry, source: candidate.source)
            else { continue }
            return match
        }
        return nil
    }

    func recordManualCorrection(_ keys: SmartLearningKeyBuilder.Keys, lang: LangChoice) {
        guard let key = keys.exact ?? keys.component ?? keys.context else { return }
        update(key) { entry in
            entry.addPositive(lang, weight: 2)
        }
    }

    func recordNegativeFeedback(_ keys: SmartLearningKeyBuilder.Keys, against lang: LangChoice) {
        guard let key = keys.exact ?? keys.component ?? keys.context else { return }
        update(key) { entry in
            entry.addNegative(against: lang)
        }
    }

    func reinforce(_ keys: SmartLearningKeyBuilder.Keys, lang: LangChoice) {
        guard let key = keys.exact else { return }
        update(key) { entry in
            entry.addPositive(lang, weight: 1)
        }
    }

    private func update(_ key: SmartLearningKey, mutate: (inout Entry) -> Void) {
        var entry = entries[key.rawValue] ?? Entry(
            englishVotes: 0,
            chineseVotes: 0,
            negativeEnglishVotes: 0,
            negativeChineseVotes: 0,
            updatedAt: Date()
        )
        mutate(&entry)
        entries[key.rawValue] = entry
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
        logger.debug("trimmed smart learning entries count=\(overflow, privacy: .public) capacity=\(self.capacity, privacy: .public)")
    }

    private func save() {
        count = entries.count
        let envelope = StorageEnvelope(
            schemaVersion: 1,
            activeKeyVersion: SmartLearningKeyBuilder.version,
            entries: entries,
            archivedEntries: archivedEntries
        )
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        defaults.set(data, forKey: key)
    }

    private func match(for key: SmartLearningKey, entry: Entry, source: String) -> SmartLearningMatch? {
        let englishScore = entry.englishVotes - entry.negativeVotes(against: .english)
        let chineseScore = entry.chineseVotes - entry.negativeVotes(against: .chinese)
        let lang: LangChoice
        let winningScore: Int
        let losingScore: Int
        if englishScore > chineseScore {
            lang = .english
            winningScore = englishScore
            losingScore = chineseScore
        } else if chineseScore > englishScore {
            lang = .chinese
            winningScore = chineseScore
            losingScore = englishScore
        } else {
            return nil
        }

        guard winningScore >= 2 else { return nil }
        let effectiveTotal = max(1, max(0, englishScore) + max(0, chineseScore))
        let confidence = Double(winningScore) / Double(effectiveTotal)
        guard confidence >= 0.66,
              winningScore - losingScore >= 1
        else { return nil }
        return SmartLearningMatch(key: key, lang: lang, confidence: confidence, source: source)
    }
}
