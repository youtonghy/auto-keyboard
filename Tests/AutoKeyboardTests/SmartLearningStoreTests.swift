import XCTest

@testable import AutoKeyboard

@MainActor
final class SmartLearningStoreTests: XCTestCase {
    private struct StoredEntry: Codable {
        var englishVotes: Int
        var chineseVotes: Int
        var negativeEnglishVotes: Int
        var negativeChineseVotes: Int
        var updatedAt: Date
    }

    private struct StoredEnvelope: Codable {
        var schemaVersion: Int
        var activeKeyVersion: String
        var entries: [String: StoredEntry]
        var archivedEntries: [String: StoredEntry]
    }

    func testPersistsAcrossStoreInstances() {
        let defaults = isolatedDefaults()
        let keys = learningKeys("component")

        SmartLearningStore(defaults: defaults, key: "learning").recordManualCorrection(keys, lang: .chinese)
        let restored = SmartLearningStore(defaults: defaults, key: "learning")

        XCTAssertEqual(restored.lookup(keys)?.lang, .chinese)
        XCTAssertEqual(restored.count, 1)
    }

    func testSingleOppositeVoteDoesNotOverwriteConfidentValue() {
        let store = SmartLearningStore(defaults: isolatedDefaults(), key: "learning")
        let keys = learningKeys("component")

        store.recordManualCorrection(keys, lang: .chinese)
        store.reinforce(keys, lang: .english)

        XCTAssertEqual(store.lookup(keys)?.lang, .chinese)
        XCTAssertEqual(store.count, 1)
    }

    func testClearRemovesPersistedValues() {
        let defaults = isolatedDefaults()
        let keys = learningKeys("component")
        let store = SmartLearningStore(defaults: defaults, key: "learning")

        store.recordManualCorrection(keys, lang: .chinese)
        store.clear()

        XCTAssertNil(SmartLearningStore(defaults: defaults, key: "learning").lookup(keys))
    }

    func testOldLearningKeysAreIgnoredOnRestore() {
        let defaults = isolatedDefaults()
        let oldKey = SmartLearningKey(rawValue: "smart-component:v2:old")
        let oldKeys = SmartLearningKeyBuilder.Keys(exact: oldKey, component: nil, context: nil)
        let store = SmartLearningStore(defaults: defaults, key: "learning")

        store.recordManualCorrection(oldKeys, lang: .chinese)
        let restored = SmartLearningStore(defaults: defaults, key: "learning")

        XCTAssertNil(restored.lookup(oldKeys))
        XCTAssertEqual(restored.count, 0)
    }

    func testRestoresLegacyDictionaryStorage() throws {
        let defaults = isolatedDefaults()
        let keys = learningKeys("legacy")
        let key = try XCTUnwrap(keys.exact)
        let legacy = [
            key.rawValue: StoredEntry(
                englishVotes: 0,
                chineseVotes: 2,
                negativeEnglishVotes: 0,
                negativeChineseVotes: 0,
                updatedAt: Date()
            ),
        ]
        defaults.set(try JSONEncoder().encode(legacy), forKey: "learning")

        let restored = SmartLearningStore(defaults: defaults, key: "learning")

        XCTAssertEqual(restored.lookup(keys)?.lang, .chinese)
    }

    func testUnknownVersionEntriesAreArchivedOnSave() throws {
        let defaults = isolatedDefaults()
        let oldKey = "smart-component:v3:old"
        let envelope = StoredEnvelope(
            schemaVersion: 1,
            activeKeyVersion: "smart-component:v5",
            entries: [
                oldKey: StoredEntry(
                    englishVotes: 2,
                    chineseVotes: 0,
                    negativeEnglishVotes: 0,
                    negativeChineseVotes: 0,
                    updatedAt: Date()
                ),
            ],
            archivedEntries: [:]
        )
        defaults.set(try JSONEncoder().encode(envelope), forKey: "learning")

        let store = SmartLearningStore(defaults: defaults, key: "learning")
        store.recordManualCorrection(learningKeys("current"), lang: .chinese)

        let data = try XCTUnwrap(defaults.data(forKey: "learning"))
        let saved = try JSONDecoder().decode(StoredEnvelope.self, from: data)
        XCTAssertNotNil(saved.archivedEntries[oldKey])
    }

    func testTrimToCapacityKeepsCountWithinLimit() {
        let store = SmartLearningStore(defaults: isolatedDefaults(), key: "learning", capacity: 2)

        store.recordManualCorrection(learningKeys("one"), lang: .chinese)
        store.recordManualCorrection(learningKeys("two"), lang: .english)
        store.recordManualCorrection(learningKeys("three"), lang: .chinese)

        XCTAssertEqual(store.count, 2)
    }

    func testLowConfidenceSingleReinforcementDoesNotApply() {
        let store = SmartLearningStore(defaults: isolatedDefaults(), key: "learning")
        let keys = learningKeys("component")

        store.reinforce(keys, lang: .chinese)

        XCTAssertNil(store.lookup(keys))
    }

    func testNegativeFeedbackSuppressesAutomaticLanguage() {
        let store = SmartLearningStore(defaults: isolatedDefaults(), key: "learning")
        let keys = learningKeys("component")

        store.recordManualCorrection(keys, lang: .chinese)
        store.recordNegativeFeedback(keys, against: .chinese)
        store.recordNegativeFeedback(keys, against: .chinese)

        XCTAssertNil(store.lookup(keys))
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "AutoKeyboardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func learningKeys(_ suffix: String) -> SmartLearningKeyBuilder.Keys {
        SmartLearningKeyBuilder.Keys(
            exact: SmartLearningKey(rawValue: "\(SmartLearningKeyBuilder.version):\(suffix)"),
            component: nil,
            context: nil
        )
    }
}
