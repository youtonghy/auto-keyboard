import ApplicationServices
import XCTest

@testable import AutoKeyboard

@MainActor
final class RuleEngineTests: XCTestCase {
    private let englishSource = "en"
    private let chineseSource = "zh"
    private let componentKey = SmartLearningKey(rawValue: "component")

    func testSmartModeLearnsFirstManualCorrectionAndRestoresIt() async {
        let harness = makeHarness(smartKey: .component)
        let focus = makeFocus()

        await harness.engine.evaluate(focus: focus, trigger: .elementChanged)
        harness.engine.noteManualSwitch(sourceID: chineseSource, focus: focus)
        harness.sources.currentID = englishSource
        await harness.engine.evaluate(focus: focus, trigger: .elementChanged)

        XCTAssertEqual(harness.smartLearning.lookup(componentKey), .chinese)
        XCTAssertEqual(harness.sources.selectedIDs, [chineseSource])
    }

    func testSecondManualSwitchInSameFocusEntryIsTransient() async {
        let harness = makeHarness(smartKey: .component)
        let focus = makeFocus()

        await harness.engine.evaluate(focus: focus, trigger: .elementChanged)
        harness.engine.noteManualSwitch(sourceID: chineseSource, focus: focus)
        harness.engine.noteManualSwitch(sourceID: englishSource, focus: focus)

        XCTAssertEqual(harness.smartLearning.lookup(componentKey), .chinese)
    }

    func testNextFocusEntryCanOverwriteLearnedValue() async {
        let harness = makeHarness(smartKey: .component)
        let focus = makeFocus()

        await harness.engine.evaluate(focus: focus, trigger: .elementChanged)
        harness.engine.noteManualSwitch(sourceID: chineseSource, focus: focus)
        await harness.engine.evaluate(focus: focus, trigger: .elementChanged)
        harness.engine.noteManualSwitch(sourceID: englishSource, focus: focus)

        XCTAssertEqual(harness.smartLearning.lookup(componentKey), .english)
    }

    func testForceModeDoesNotLearn() {
        let harness = makeHarness(defaultMode: .forceEnglish)

        harness.engine.noteManualSwitch(sourceID: chineseSource, focus: makeFocus())

        XCTAssertNil(harness.smartLearning.lookup(componentKey))
    }

    func testNonConfiguredInputSourceDoesNotLearnOrPersistWindowMemory() {
        let harness = makeHarness()
        let focus = makeFocus()

        harness.engine.noteManualSwitch(sourceID: "emoji", focus: focus)

        XCTAssertNil(harness.smartLearning.lookup(componentKey))
        XCTAssertNil(harness.memory.lookup(focus.key))
    }

    func testLearnedHitSuppressesSelectionChangedSmartDetection() async {
        let harness = makeHarness(
            smartKey: .component,
            decision: ContextDecision(kind: .normalTextInput, lang: .chinese, source: "cursor-text")
        )
        let focus = makeFocus(windowTitle: "English title")
        harness.smartLearning.record(componentKey, lang: .chinese)

        await harness.engine.evaluate(focus: focus, trigger: .elementChanged)
        harness.sources.selectedIDs.removeAll()
        await harness.engine.evaluate(focus: focus, trigger: .selectionChanged)

        XCTAssertEqual(harness.sources.currentID, chineseSource)
        XCTAssertTrue(harness.sources.selectedIDs.isEmpty)
    }

    func testSmartModeUsesLearningBeforeKeywordRules() async {
        let harness = makeHarness(
            appRules: [
                AppRule(
                    bundleID: "com.example.app",
                    displayName: "Example",
                    mode: .smart,
                    keywordRules: [KeywordRule(keyword: "codex", lang: .chinese)]
                ),
            ],
            smartKey: .component,
            decision: ContextDecision(kind: .normalTextInput, lang: .english, source: "window-title")
        )
        let focus = makeFocus(windowTitle: "codex")
        harness.smartLearning.record(componentKey, lang: .english)
        harness.sources.currentID = chineseSource

        await harness.engine.evaluate(focus: focus, trigger: .elementChanged)

        XCTAssertEqual(harness.sources.selectedIDs, [englishSource])
    }

    func testSmartModeUsesKeywordBeforeDetectedTitleLanguage() async {
        let harness = makeHarness(appRules: [
            AppRule(
                bundleID: "com.example.app",
                displayName: "Example",
                mode: .smart,
                keywordRules: [KeywordRule(keyword: "codex", lang: .chinese)]
            ),
        ])
        let focus = makeFocus(windowTitle: "codex english title")

        await harness.engine.evaluate(focus: focus, trigger: .elementChanged)

        XCTAssertEqual(harness.sources.selectedIDs, [chineseSource])
    }

    func testWindowSwitchViaElementChangedAppliesNewWindowMemory() async {
        let harness = makeHarness(defaultMode: .memory)
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
                    bundleID: "com.example.app",
                    displayName: "Example",
                    mode: .memory,
                    defaultLang: .english
                ),
            ]
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
        ])
        let focus = makeFocus(bundleID: "com.openai.codex", appName: "Codex", windowTitle: "Codex")

        await harness.engine.evaluate(focus: focus, trigger: .appActivated)

        XCTAssertEqual(harness.sources.selectedIDs, [chineseSource])
    }

    func testBlackBoxCodexWithoutMemoryOrDefaultDoesNotGuessChinese() async {
        let harness = makeHarness()
        let focus = makeFocus(bundleID: "com.openai.codex", appName: "Codex", windowTitle: "Codex")
        harness.sources.currentID = englishSource

        await harness.engine.evaluate(focus: focus, trigger: .selectionChanged)

        XCTAssertTrue(harness.sources.selectedIDs.isEmpty)
        XCTAssertEqual(harness.sources.currentID, englishSource)
    }

    func testBlackBoxCodexRestoresWindowMemoryInSmartMode() async {
        let harness = makeHarness()
        let focus = makeFocus(bundleID: "com.openai.codex", appName: "Codex", windowTitle: "Codex")
        harness.memory.record(focus.key, sourceID: chineseSource)

        await harness.engine.evaluate(focus: focus, trigger: .appActivated)

        XCTAssertEqual(harness.sources.selectedIDs, [chineseSource])
    }

    func testBlackBoxCodexManualSwitchRecordsOnlyWindowMemory() {
        let harness = makeHarness(capability: .blackBox)
        let focus = makeFocus(bundleID: "com.openai.codex", appName: "Codex", windowTitle: "Codex")

        harness.engine.noteManualSwitch(sourceID: chineseSource, focus: focus)

        XCTAssertEqual(harness.memory.lookup(focus.key), chineseSource)
        XCTAssertNil(harness.smartLearning.lookup(componentKey))
    }

    func testSmartBlackBoxBlocksOCRForNonInputClick() async {
        let harness = makeHarness(defaultMode: .smart, capability: .blackBox)
        let focus = makeFocus(
            bundleID: "com.openai.codex",
            appName: "Codex",
            windowTitle: "Codex",
            hitElement: makeElement(),
            focusPoint: CGPoint(x: 100, y: 100)
        )
        harness.sources.currentID = englishSource

        await harness.engine.evaluate(focus: focus, trigger: .elementChanged)

        XCTAssertTrue(harness.sources.selectedIDs.isEmpty)
        XCTAssertEqual(harness.sources.currentID, englishSource)
        XCTAssertTrue(harness.ocrCalls.values.isEmpty)
    }

    func testSmartBlackBoxRunsOCRForInputClickElementChanged() async {
        let harness = makeHarness(defaultMode: .smart, ocrAssistedDetection: true, capability: .blackBox, clickInputCandidate: true, ocrText: "中文输入")
        let focus = makeFocus(
            bundleID: "com.openai.codex",
            appName: "Codex",
            windowTitle: "Codex",
            hitElement: makeElement(),
            focusPoint: CGPoint(x: 100, y: 100)
        )
        harness.sources.currentID = englishSource

        await harness.engine.evaluate(focus: focus, trigger: .elementChanged)

        XCTAssertEqual(harness.ocrCalls.values.count, 1)
        XCTAssertEqual(harness.sources.selectedIDs, [chineseSource])
    }

    func testSmartBlackBoxDoesNotRunOCRForButtonClick() async {
        let harness = makeHarness(defaultMode: .smart, ocrAssistedDetection: true, capability: .blackBox, clickInputCandidate: false, ocrText: "中文输入")
        let focus = makeFocus(
            bundleID: "com.openai.codex",
            appName: "Codex",
            windowTitle: "Codex",
            hitElement: makeElement(),
            focusPoint: CGPoint(x: 100, y: 100)
        )
        harness.sources.currentID = englishSource

        await harness.engine.evaluate(focus: focus, trigger: .elementChanged)

        XCTAssertTrue(harness.ocrCalls.values.isEmpty)
        XCTAssertTrue(harness.sources.selectedIDs.isEmpty)
    }

    func testSmartBlackBoxRunsOCRForUnknownClickInScrollArea() async {
        let harness = makeHarness(defaultMode: .smart, ocrAssistedDetection: true, capability: .blackBox, clickInputCandidate: nil, ocrText: "中文输入")
        let focus = makeFocus(
            bundleID: "com.openai.codex",
            appName: "Codex",
            windowTitle: "Codex",
            hitElement: makeElement(),
            focusPoint: CGPoint(x: 100, y: 100)
        )
        harness.sources.currentID = englishSource

        await harness.engine.evaluate(focus: focus, trigger: .elementChanged)

        XCTAssertEqual(harness.ocrCalls.values.count, 1)
        XCTAssertEqual(harness.sources.selectedIDs, [chineseSource])
    }

    func testBlackBoxInputClickUsesExpandedClickPointCaptureArea() async {
        let harness = makeHarness(defaultMode: .smart, ocrAssistedDetection: true, capability: .blackBox, clickInputCandidate: nil, ocrText: "中文输入")
        let focus = makeFocus(
            bundleID: "com.openai.codex",
            appName: "Codex",
            windowTitle: "Codex",
            hitElement: makeElement(),
            focusPoint: CGPoint(x: 120, y: 220)
        )
        harness.sources.currentID = englishSource

        await harness.engine.evaluate(focus: focus, trigger: .elementChanged)

        XCTAssertEqual(harness.ocrCalls.values.count, 1)
        let captureRect = harness.ocrCalls.values[0].1
        XCTAssertGreaterThan(captureRect.width, 100)
        XCTAssertGreaterThan(captureRect.height, 40)
    }

    func testClickIntentHelperRecognizesInputAndNonInputRoles() {
        XCTAssertEqual(ContextDetector.isClickInputCandidate(role: "AXTextField"), true)
        XCTAssertEqual(ContextDetector.isClickInputCandidate(role: "AXButton"), false)
        XCTAssertNil(ContextDetector.isClickInputCandidate(role: "AXGroup"))
    }

    func testBlackBoxScrollAreaCanBeTreatedAsInputCandidate() {
        XCTAssertTrue(ContextDetector.isBlackBoxScrollAreaInputCandidate(
            bundleID: "com.openai.codex",
            role: "AXScrollArea"
        ))
        XCTAssertFalse(ContextDetector.isBlackBoxScrollAreaInputCandidate(
            bundleID: "com.example.app",
            role: "AXScrollArea"
        ))
    }

    func testBlackBoxScrollAreaDescendantCanBeTreatedAsInputCandidate() async {
        let harness = makeHarness(defaultMode: .smart, ocrAssistedDetection: true, capability: .blackBox, clickInputCandidate: nil, ocrText: "中文输入")
        let parent = makeElement()
        let focus = makeFocus(
            bundleID: "com.openai.codex",
            appName: "Codex",
            windowTitle: "Codex",
            hitElement: parent,
            focusPoint: CGPoint(x: 100, y: 100)
        )
        harness.sources.currentID = englishSource

        await harness.engine.evaluate(focus: focus, trigger: .elementChanged)

        XCTAssertEqual(harness.ocrCalls.values.count, 1)
        XCTAssertEqual(harness.sources.selectedIDs, [chineseSource])
    }

    func testValueChangedTriggerIsTreatedAsContentChange() async {
        let harness = makeHarness(defaultMode: .memory)
        let focus = makeFocus(windowTitle: "win-a")
        harness.memory.record(focus.key, sourceID: englishSource)

        await harness.engine.evaluate(focus: focus, trigger: .valueChanged)

        XCTAssertTrue(harness.sources.selectedIDs.isEmpty)
    }

    func testSelectionChangedStillAllowsOCRInBlackBox() async {
        let harness = makeHarness(defaultMode: .smart, ocrAssistedDetection: true, capability: .blackBox, clickInputCandidate: nil, ocrText: "english text")
        let focus = makeFocus(
            bundleID: "com.openai.codex",
            appName: "Codex",
            windowTitle: "Codex",
            hitElement: makeElement(),
            focusPoint: CGPoint(x: 100, y: 100)
        )
        harness.sources.currentID = chineseSource

        await harness.engine.evaluate(focus: focus, trigger: .selectionChanged)

        XCTAssertEqual(harness.ocrCalls.values.count, 1)
        XCTAssertEqual(harness.sources.selectedIDs, [englishSource])
    }

    func testAutoSwitchDoesNotSetManualOverride() async {
        let harness = makeHarness(
            defaultMode: .smart,
            appRules: [
                AppRule(
                    bundleID: "com.example.app",
                    displayName: "Example",
                    mode: .smart,
                    defaultLang: .chinese
                ),
            ],
            ocrText: "中文输入"
        )
        let focus = makeFocus(windowTitle: "win-a")

        await harness.engine.evaluate(focus: focus, trigger: .appActivated)

        XCTAssertEqual(harness.sources.selectedIDs, [chineseSource])
        harness.sources.selectedIDs.removeAll()
        harness.sources.currentID = chineseSource
        await harness.engine.evaluate(focus: focus, trigger: .elementChanged)

        XCTAssertTrue(harness.sources.selectedIDs.isEmpty)
    }

    func testTerminalContentChangeCanSwitchToEnglishInMemoryMode() async {
        let harness = makeHarness(defaultMode: .memory)
        let focus = makeFocus(bundleID: "com.apple.Terminal", appName: "Terminal", windowTitle: "Terminal")
        harness.sources.currentID = chineseSource

        await harness.engine.evaluate(focus: focus, trigger: .selectionChanged)

        XCTAssertTrue(harness.sources.selectedIDs.isEmpty)
    }

    func testContextKindSeparatesLearnedValues() async {
        let harness = makeHarness(
            contextKeyedLearning: true,
            smartKey: .contextDriven,
            decision: ContextDecision(kind: .assistantChatInput, lang: .english, source: "assistant-chat")
        )
        let chatFocus = makeFocus(bundleID: "com.example.chat", appName: "Chat", windowTitle: "Chat input")
        let terminalFocus = makeFocus(bundleID: "com.apple.Terminal", appName: "Terminal", windowTitle: "Terminal")

        await harness.engine.evaluate(focus: chatFocus, trigger: .appActivated)
        harness.engine.noteManualSwitch(sourceID: chineseSource, focus: chatFocus)
        harness.smartLearning.record(SmartLearningKey(rawValue: "component:terminalShell"), lang: .english)
        harness.sources.currentID = chineseSource
        harness.sources.selectedIDs.removeAll()

        await harness.engine.evaluate(focus: terminalFocus, trigger: .appActivated)

        XCTAssertEqual(harness.smartLearning.lookup(SmartLearningKey(rawValue: "component:assistantChatInput")), .chinese)
        XCTAssertTrue(harness.sources.selectedIDs.isEmpty)
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

    private func makeHarness(
        defaultMode: AppMode = .smart,
        smartLearningEnabled: Bool = true,
        ocrAssistedDetection: Bool = false,
        appRules: [AppRule] = [],
        contextKeyedLearning: Bool = false,
        smartKey: SmartKeyMode = .none,
        capability: AXCapability = .componentVisible,
        clickInputCandidate: Bool? = nil,
        decision: ContextDecision? = nil,
        ocrText: String? = nil
    ) -> Harness {
        let defaults = UserDefaults(suiteName: "RuleEngineTests.\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults, key: "settings")
        settings.value = AppSettings(
            englishSourceID: englishSource,
            chineseSourceID: chineseSource,
            defaultMode: defaultMode,
            smartLearningEnabled: smartLearningEnabled,
            ocrAssistedDetection: ocrAssistedDetection,
            appRules: appRules
        )
        let sources = FakeInputSourceManager(currentID: englishSource)
        let memory = FakeWindowStateStore()
        let smartLearning = FakeSmartLearningStore()
        let ocrCalls = Recorder<(CGRect, CGRect, String?)>()
        let engine = RuleEngine(
            settings: settings,
            sources: sources,
            memory: memory,
            smartLearning: smartLearning,
            smartKeyForFocus: { _, contextKind in
                switch smartKey {
                case .none:
                    return self.componentKey
                case .component:
                    return self.componentKey
                case .contextDriven:
                    return contextKeyedLearning
                        ? SmartLearningKey(rawValue: "component:\(contextKind.rawValue)")
                        : self.componentKey
                }
            },
            capabilityForFocus: { _ in capability },
            decisionForFocus: { _, _ in decision },
            clickInputCandidateForHitElement: { element in
                guard element != nil else { return nil }
                return clickInputCandidate
            },
            caretLocationForFocus: { _, _ in
                AXGeometry.CaretLocation(
                    rect: CGRect(x: 100, y: 100, width: 10, height: 20),
                    source: "test"
                )
            },
            screenCaptureTrustedForOCR: { true },
            ocrRunner: { caretRect, captureRect, token in
                ocrCalls.values.append((caretRect, captureRect, token))
                return ocrText
            }
        )
        return Harness(
            engine: engine,
            sources: sources,
            memory: memory,
            smartLearning: smartLearning,
            ocrCalls: ocrCalls
        )
    }

    private func makeFocus(
        bundleID: String = "com.example.app",
        appName: String = "Example",
        windowTitle: String = "Test",
        element: AXUIElement? = nil,
        hitElement: AXUIElement? = nil,
        focusPoint: CGPoint? = nil
    ) -> FocusTracker.Focus {
        FocusTracker.Focus(
            bundleID: bundleID,
            appName: appName,
            window: nil,
            windowTitle: windowTitle,
            element: element,
            hitElement: hitElement,
            focusPoint: focusPoint
        )
    }

    private func makeElement() -> AXUIElement {
        AXUIElementCreateApplication(0)
    }

    private enum SmartKeyMode {
        case none
        case component
        case contextDriven
    }
}

@MainActor
private struct Harness {
    let engine: RuleEngine
    let sources: FakeInputSourceManager
    let memory: FakeWindowStateStore
    let smartLearning: FakeSmartLearningStore
    let ocrCalls: Recorder<(CGRect, CGRect, String?)>
}

private final class Recorder<Value> {
    var values: [Value] = []
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
