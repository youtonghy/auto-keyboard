import XCTest

@testable import AutoKeyboard

@MainActor
final class RuleEngineTests: XCTestCase {
    private let englishSource = "en"
    private let chineseSource = "zh"
    private let componentKey = SmartLearningKey(rawValue: "component")

    func testSmartModeLearnsFirstManualCorrectionAndRestoresIt() async {
        let harness = makeHarness(axCapability: .componentVisible)
        let focus = makeFocus()

        await harness.engine.evaluate(focus: focus, trigger: .elementChanged)
        harness.engine.noteManualSwitch(sourceID: chineseSource, focus: focus)
        harness.sources.currentID = englishSource
        await harness.engine.evaluate(focus: focus, trigger: .elementChanged)

        XCTAssertEqual(harness.smartLearning.lookup(componentKey), .chinese)
        XCTAssertEqual(harness.sources.selectedIDs, [chineseSource])
    }

    func testSecondManualSwitchInSameFocusEntryIsTransient() async {
        let harness = makeHarness(axCapability: .componentVisible)
        let focus = makeFocus()

        await harness.engine.evaluate(focus: focus, trigger: .elementChanged)
        harness.engine.noteManualSwitch(sourceID: chineseSource, focus: focus)
        harness.engine.noteManualSwitch(sourceID: englishSource, focus: focus)

        XCTAssertEqual(harness.smartLearning.lookup(componentKey), .chinese)
    }

    func testNextFocusEntryCanOverwriteLearnedValue() async {
        let harness = makeHarness(axCapability: .componentVisible)
        let focus = makeFocus()

        await harness.engine.evaluate(focus: focus, trigger: .elementChanged)
        harness.engine.noteManualSwitch(sourceID: chineseSource, focus: focus)
        await harness.engine.evaluate(focus: focus, trigger: .elementChanged)
        harness.engine.noteManualSwitch(sourceID: englishSource, focus: focus)

        XCTAssertEqual(harness.smartLearning.lookup(componentKey), .english)
    }

    func testForceModeDoesNotLearn() {
        let harness = makeHarness(defaultMode: .forceEnglish, axCapability: .componentVisible)

        harness.engine.noteManualSwitch(sourceID: chineseSource, focus: makeFocus())

        XCTAssertNil(harness.smartLearning.lookup(componentKey))
    }

    func testNonConfiguredInputSourceDoesNotLearnOrPersistWindowMemory() {
        let harness = makeHarness(axCapability: .componentVisible)
        let focus = makeFocus()

        harness.engine.noteManualSwitch(sourceID: "emoji", focus: focus)

        XCTAssertNil(harness.smartLearning.lookup(componentKey))
        XCTAssertNil(harness.memory.lookup(focus.key))
    }

    func testLearnedHitSuppressesSelectionChangedSmartDetection() async {
        let harness = makeHarness(axCapability: .componentVisible)
        let focus = makeFocus(windowTitle: "English title")
        harness.smartLearning.record(componentKey, lang: .chinese)

        await harness.engine.evaluate(focus: focus, trigger: .elementChanged)
        harness.sources.selectedIDs.removeAll()
        await harness.engine.evaluate(focus: focus, trigger: .selectionChanged)

        XCTAssertEqual(harness.sources.currentID, chineseSource)
        XCTAssertTrue(harness.sources.selectedIDs.isEmpty)
    }

    func testWindowSwitchViaElementChangedAppliesNewWindowMemory() async {
        let harness = makeHarness(defaultMode: .memory, axCapability: .componentVisible)
        let focusA = makeFocus(windowTitle: "win-a")
        let focusB = makeFocus(windowTitle: "win-b")
        harness.memory.record(focusB.key, sourceID: englishSource)

        await harness.engine.evaluate(focus: focusA, trigger: .appActivated)
        harness.engine.noteManualSwitch(sourceID: chineseSource, focus: focusA)
        harness.sources.currentID = chineseSource
        harness.sources.selectedIDs.removeAll()

        await harness.engine.evaluate(focus: focusB, trigger: .elementChanged)

        XCTAssertEqual(harness.sources.selectedIDs, [englishSource])
    }

    func testSameWindowElementChangeKeepsManualOverride() async {
        let harness = makeHarness(
            defaultMode: .memory,
            smartLearningEnabled: false,
            appRules: [
                AppRule(
                    bundleID: "com.apple.Terminal",
                    displayName: "Terminal",
                    mode: .memory,
                    defaultLang: .english
                ),
            ]
            ,
            axCapability: .componentVisible
        )
        let focus = makeFocus(windowTitle: "win-a")

        await harness.engine.evaluate(focus: focus, trigger: .appActivated)
        harness.engine.noteManualSwitch(sourceID: chineseSource, focus: focus)
        harness.sources.currentID = chineseSource
        harness.sources.selectedIDs.removeAll()

        await harness.engine.evaluate(focus: focus, trigger: .elementChanged)

        XCTAssertTrue(harness.sources.selectedIDs.isEmpty)
        XCTAssertEqual(harness.sources.currentID, chineseSource)
    }

    func testBlackBoxCodexUsesAppDefaultInsteadOfSmartFallback() async {
        let harness = makeHarness(appRules: [
            AppRule(
                bundleID: "com.openai.codex",
                displayName: "Codex",
                mode: .smart,
                defaultLang: .chinese
            ),
        ], axCapability: .blackBox, waitBeforeBlackBoxRetry: {})
        let focus = makeFocus(bundleID: "com.openai.codex", appName: "Codex", windowTitle: "Codex")

        await harness.engine.evaluate(focus: focus, trigger: .appActivated)

        XCTAssertEqual(harness.sources.selectedIDs, [chineseSource])
    }

    func testBlackBoxCodexWithoutMemoryOrDefaultDoesNotGuessChinese() async {
        let harness = makeHarness(axCapability: .blackBox, waitBeforeBlackBoxRetry: {})
        let focus = makeFocus(bundleID: "com.openai.codex", appName: "Codex", windowTitle: "Codex")
        harness.sources.currentID = englishSource

        await harness.engine.evaluate(focus: focus, trigger: .selectionChanged)

        XCTAssertTrue(harness.sources.selectedIDs.isEmpty)
        XCTAssertEqual(harness.sources.currentID, englishSource)
    }

    func testBlackBoxCodexRestoresWindowMemoryInSmartMode() async {
        let harness = makeHarness(axCapability: .blackBox, waitBeforeBlackBoxRetry: {})
        let focus = makeFocus(bundleID: "com.openai.codex", appName: "Codex", windowTitle: "Codex")
        harness.memory.record(focus.key, sourceID: chineseSource)

        await harness.engine.evaluate(focus: focus, trigger: .appActivated)

        XCTAssertEqual(harness.sources.selectedIDs, [chineseSource])
    }

    func testBlackBoxFocusEntryRetriesAndUsesRecoveredSmartDecision() async {
        let harness = makeHarness(
            snapshots: [
                ContextDetector.FocusSnapshot(
                    elementNodes: [],
                    cursorText: nil,
                    regionText: nil,
                    windowText: nil,
                    hasElement: false
                ),
                ContextDetector.FocusSnapshot(
                    elementNodes: [
                        ContextDetector.FocusRegionNode(role: "AXTextArea", shortTexts: ["输入消息"]),
                    ],
                    cursorText: nil,
                    regionText: nil,
                    windowText: nil,
                    hasElement: true
                ),
            ],
            waitBeforeBlackBoxRetry: {}
        )
        let focus = makeFocus(bundleID: "com.openai.codex", appName: "Codex", windowTitle: "Codex")

        await harness.engine.evaluate(focus: focus, trigger: .appActivated)

        XCTAssertEqual(harness.sources.selectedIDs, [chineseSource])
    }

    func testSmartModeFallsBackToWindowMemoryWhenAXIsNotComponentVisible() async {
        let harness = makeHarness(
            appRules: [
                AppRule(
                    bundleID: "com.example.app",
                    displayName: "Example",
                    mode: .smart,
                    defaultLang: .english
                ),
            ]
            , axCapability: .textVisible
        )
        let focus = makeFocus(bundleID: "com.example.app", appName: "Example", windowTitle: "Test")
        harness.memory.record(focus.key, sourceID: chineseSource)

        await harness.engine.evaluate(focus: focus, trigger: .selectionChanged)

        XCTAssertEqual(harness.sources.selectedIDs, [chineseSource])
    }

    func testBlackBoxCodexManualSwitchRecordsOnlyWindowMemory() {
        let harness = makeHarness(axCapability: .blackBox)
        let focus = makeFocus(bundleID: "com.openai.codex", appName: "Codex", windowTitle: "Codex")

        harness.engine.noteManualSwitch(sourceID: chineseSource, focus: focus)

        XCTAssertEqual(harness.memory.lookup(focus.key), chineseSource)
        XCTAssertNil(harness.smartLearning.lookup(componentKey))
    }

    func testTerminalContentChangeCanSwitchToEnglishInMemoryMode() async {
        let harness = makeHarness(defaultMode: .memory, axCapability: .componentVisible)
        let focus = makeFocus(bundleID: "com.apple.Terminal", appName: "Terminal", windowTitle: "Terminal")
        harness.sources.currentID = chineseSource

        await harness.engine.evaluate(focus: focus, trigger: .selectionChanged)

        XCTAssertEqual(harness.sources.selectedIDs, [englishSource])
    }

    func testContextKindSeparatesLearnedValues() async {
        let harness = makeHarness(contextKeyedLearning: true, axCapability: .componentVisible)
        let chatFocus = makeFocus(bundleID: "com.example.chat", appName: "Chat", windowTitle: "Chat input")
        let terminalFocus = makeFocus(bundleID: "com.apple.Terminal", appName: "Terminal", windowTitle: "Terminal")

        await harness.engine.evaluate(focus: chatFocus, trigger: .appActivated)
        harness.engine.noteManualSwitch(sourceID: chineseSource, focus: chatFocus)
        harness.smartLearning.record(SmartLearningKey(rawValue: "component:terminalShell"), lang: .english)
        harness.sources.currentID = chineseSource
        harness.sources.selectedIDs.removeAll()

        await harness.engine.evaluate(focus: terminalFocus, trigger: .appActivated)

        XCTAssertEqual(harness.smartLearning.lookup(SmartLearningKey(rawValue: "component:assistantChatInput")), .chinese)
        XCTAssertEqual(harness.sources.selectedIDs, [englishSource])
    }

    func testKeywordRuleCanOverrideAfterManualOverride() async {
        let harness = makeHarness(
            defaultMode: .memory,
            appRules: [
                AppRule(
                    bundleID: "com.apple.Terminal",
                    displayName: "Terminal",
                    mode: .memory,
                    defaultLang: .english,
                    keywordRules: [KeywordRule(keyword: "codex", lang: .chinese)]
                ),
            ]
            ,
            axCapability: .componentVisible
        )
        let shellFocus = makeFocus(bundleID: "com.apple.Terminal", appName: "Terminal", windowTitle: "Terminal")
        let agentFocus = makeFocus(bundleID: "com.apple.Terminal", appName: "Terminal", windowTitle: "codex")

        await harness.engine.evaluate(focus: shellFocus, trigger: .appActivated)
        harness.engine.noteManualSwitch(sourceID: englishSource, focus: shellFocus)
        harness.sources.selectedIDs.removeAll()
        harness.sources.currentID = englishSource

        await harness.engine.evaluate(focus: agentFocus, trigger: .titleChanged)

        XCTAssertEqual(harness.sources.selectedIDs, [chineseSource])
    }

    func testKeywordRuleDoesNotSwitchOnSelectionChanged() async {
        let harness = makeHarness(
            defaultMode: .memory,
            appRules: [
                AppRule(
                    bundleID: "com.example.app",
                    displayName: "Example",
                    mode: .memory,
                    defaultLang: .english,
                    keywordRules: [KeywordRule(keyword: "codex", lang: .chinese)]
                ),
            ],
            axCapability: .componentVisible
        )
        let focus = makeFocus(bundleID: "com.example.app", appName: "Example", windowTitle: "codex")
        harness.sources.currentID = englishSource

        await harness.engine.evaluate(focus: focus, trigger: .selectionChanged)

        XCTAssertTrue(harness.sources.selectedIDs.isEmpty)
        XCTAssertEqual(harness.sources.currentID, englishSource)
    }

    func testRecentTypingSkipsSelectionChangedSwitch() async {
        let harness = makeHarness(
            defaultMode: .memory,
            axCapability: .componentVisible,
            secondsSinceLastKeyDown: { 0.1 }
        )
        let focus = makeFocus(bundleID: "com.apple.Terminal", appName: "Terminal", windowTitle: "Terminal")
        harness.sources.currentID = chineseSource

        await harness.engine.evaluate(focus: focus, trigger: .selectionChanged)

        XCTAssertTrue(harness.sources.selectedIDs.isEmpty)
        XCTAssertEqual(harness.sources.currentID, chineseSource)
    }

    private func makeHarness(
        defaultMode: AppMode = .smart,
        smartLearningEnabled: Bool = true,
        appRules: [AppRule] = [],
        contextKeyedLearning: Bool = false,
        axCapability: AXCapability = .blackBox,
        secondsSinceLastKeyDown: @escaping () -> TimeInterval = { .greatestFiniteMagnitude },
        snapshots: [ContextDetector.FocusSnapshot]? = nil,
        waitBeforeBlackBoxRetry: (() async -> Void)? = nil
    ) -> Harness {
        let defaults = UserDefaults(suiteName: "RuleEngineTests.\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults, key: "settings")
        settings.value = AppSettings(
            englishSourceID: englishSource,
            chineseSourceID: chineseSource,
            defaultMode: defaultMode,
            smartLearningEnabled: smartLearningEnabled,
            appRules: appRules
        )
        let sources = FakeInputSourceManager(currentID: englishSource)
        let memory = FakeWindowStateStore()
        let smartLearning = FakeSmartLearningStore()
        var snapshotIndex = 0
        let engine = RuleEngine(
            settings: settings,
            sources: sources,
            memory: memory,
            smartLearning: smartLearning,
            smartKeyForFocus: { _, contextKind in
                contextKeyedLearning
                    ? SmartLearningKey(rawValue: "component:\(contextKind.rawValue)")
                    : self.componentKey
            },
            snapshotForFocus: { focus in
                if let snapshots, !snapshots.isEmpty {
                    let snapshot = snapshots[min(snapshotIndex, snapshots.count - 1)]
                    snapshotIndex += 1
                    return snapshot
                }
                return Self.snapshot(for: axCapability, focus: focus)
            },
            axCapabilityForFocus: { focus, snapshot in
                snapshots == nil ? axCapability : snapshot.axCapability(bundleID: focus.bundleID)
            },
            secondsSinceLastKeyDown: secondsSinceLastKeyDown,
            waitBeforeBlackBoxRetry: waitBeforeBlackBoxRetry
        )
        return Harness(
            engine: engine,
            sources: sources,
            memory: memory,
            smartLearning: smartLearning
        )
    }

    private func makeFocus(
        bundleID: String = "com.example.app",
        appName: String = "Example",
        windowTitle: String = "Test"
    ) -> FocusTracker.Focus {
        FocusTracker.Focus(
            bundleID: bundleID,
            appName: appName,
            processID: nil,
            window: nil,
            windowTitle: windowTitle,
            element: nil
        )
    }

    private static func snapshot(for capability: AXCapability, focus: FocusTracker.Focus) -> ContextDetector.FocusSnapshot {
        let elementNodes: [ContextDetector.FocusRegionNode]
        let windowText: String?
        let hasElement: Bool
        switch capability {
        case .componentVisible:
            elementNodes = [ContextDetector.FocusRegionNode(role: "AXTextArea", shortTexts: [focus.windowTitle])]
            windowText = nil
            hasElement = true
        case .textVisible:
            elementNodes = []
            windowText = focus.windowTitle
            hasElement = false
        case .blackBox:
            elementNodes = []
            windowText = nil
            hasElement = false
        }
        return ContextDetector.FocusSnapshot(
            elementNodes: elementNodes,
            cursorText: nil,
            regionText: nil,
            windowText: windowText,
            hasElement: hasElement
        )
    }
}

@MainActor
private struct Harness {
    let engine: RuleEngine
    let sources: FakeInputSourceManager
    let memory: FakeWindowStateStore
    let smartLearning: FakeSmartLearningStore
}

@MainActor
private final class FakeInputSourceManager: InputSourceManaging {
    var currentID: String
    var selectedIDs: [String] = []

    init(currentID: String) {
        self.currentID = currentID
    }

    func select(id: String) async -> Bool {
        selectedIDs.append(id)
        currentID = id
        return true
    }
}

@MainActor
private final class FakeWindowStateStore: WindowStateStoring {
    private var values: [WindowKey: String] = [:]

    func record(_ key: WindowKey, sourceID: String) {
        values[key] = sourceID
    }

    func lookup(_ key: WindowKey) -> String? {
        values[key]
    }

    func clear() {
        values.removeAll()
    }
}

@MainActor
private final class FakeSmartLearningStore: SmartLearningStoring {
    private var values: [SmartLearningKey: LangChoice] = [:]

    var count: Int { values.count }

    func lookup(_ key: SmartLearningKey) -> LangChoice? {
        values[key]
    }

    func record(_ key: SmartLearningKey, lang: LangChoice) {
        values[key] = lang
    }

    func clear() {
        values.removeAll()
    }
}
