import XCTest

@testable import AutoKeyboard

@MainActor
final class SmartLearningStoreTests: XCTestCase {
    func testPersistsAcrossStoreInstances() {
        let defaults = isolatedDefaults()
        let key = v3Key("component")

        SmartLearningStore(defaults: defaults, key: "learning").record(key, lang: .chinese)
        let restored = SmartLearningStore(defaults: defaults, key: "learning")

        XCTAssertEqual(restored.lookup(key), .chinese)
        XCTAssertEqual(restored.count, 1)
    }

    func testRecordOverwritesExistingValue() {
        let store = SmartLearningStore(defaults: isolatedDefaults(), key: "learning")
        let key = v3Key("component")

        store.record(key, lang: .chinese)
        store.record(key, lang: .english)

        XCTAssertEqual(store.lookup(key), .english)
        XCTAssertEqual(store.count, 1)
    }

    func testClearRemovesPersistedValues() {
        let defaults = isolatedDefaults()
        let key = v3Key("component")
        let store = SmartLearningStore(defaults: defaults, key: "learning")

        store.record(key, lang: .chinese)
        store.clear()

        XCTAssertNil(SmartLearningStore(defaults: defaults, key: "learning").lookup(key))
    }

    func testOldLearningKeysAreIgnoredOnRestore() {
        let defaults = isolatedDefaults()
        let oldKey = SmartLearningKey(rawValue: "smart-component:v2:old")
        let store = SmartLearningStore(defaults: defaults, key: "learning")

        store.record(oldKey, lang: .chinese)
        let restored = SmartLearningStore(defaults: defaults, key: "learning")

        XCTAssertNil(restored.lookup(oldKey))
        XCTAssertEqual(restored.count, 0)
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "AutoKeyboardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func v3Key(_ suffix: String) -> SmartLearningKey {
        SmartLearningKey(rawValue: "\(SmartLearningKeyBuilder.version):\(suffix)")
    }
}
