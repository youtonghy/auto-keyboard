import XCTest

@testable import AutoKeyboard

@MainActor
final class ContextDetectorTests: XCTestCase {
    func testClassifyChineseText() {
        XCTAssertEqual(ContextDetector.classify("中文内容你好世界"), .chinese)
    }

    func testClassifyEnglishText() {
        XCTAssertEqual(ContextDetector.classify("Hello world this is a test"), .english)
    }

    func testPlaceholderChatSemanticUsesAssistantChatInput() {
        let decision = ContextDetector.detectDecision(
            bundleID: "com.example.chat",
            windowTitle: "Assistant",
            elementNodes: [
                ContextDetector.FocusRegionNode(
                    role: "AXTextArea",
                    shortTexts: ["输入消息"]
                ),
            ],
            cursorText: nil,
            regionText: nil
        )

        XCTAssertEqual(decision?.kind, .assistantChatInput)
        XCTAssertEqual(decision?.lang, .chinese)
    }

    func testCodexWithoutAXFocusReturnsUnknownInsteadOfFallbackChinese() {
        let decision = ContextDetector.detectDecision(
            bundleID: "com.openai.codex",
            windowTitle: "Codex",
            elementNodes: [],
            cursorText: nil,
            regionText: nil,
            hasElement: false
        )

        XCTAssertNil(decision)
    }

    func testCodexWithPlaceholderStillUsesAssistantChatInput() {
        let decision = ContextDetector.detectDecision(
            bundleID: "com.openai.codex",
            windowTitle: "Codex",
            elementNodes: [
                ContextDetector.FocusRegionNode(
                    role: "AXTextArea",
                    shortTexts: ["输入消息"]
                ),
            ],
            cursorText: nil,
            regionText: nil,
            hasElement: true
        )

        XCTAssertEqual(decision?.kind, .assistantChatInput)
        XCTAssertEqual(decision?.lang, .chinese)
    }

    func testTerminalPromptDecisionUsesTerminalShell() {
        let decision = ContextDetector.detectTerminalDecision(
            bundleID: "com.apple.Terminal",
            haystack: "macToolBox",
            text: "macToolBox % ",
            regionText: nil
        )

        XCTAssertEqual(decision?.kind, .terminalShell)
        XCTAssertEqual(decision?.lang, .english)
    }

    func testCodexWindowTextPromptUsesTerminalShell() {
        let decision = ContextDetector.detectDecision(
            bundleID: "com.openai.codex",
            windowTitle: "Codex",
            elementNodes: [],
            cursorText: nil,
            regionText: nil,
            windowText: "macToolBox % ",
            hasElement: false
        )

        XCTAssertEqual(decision?.kind, .terminalShell)
        XCTAssertEqual(decision?.lang, .english)
    }

    func testAgentInRegionTailUsesTerminalAgent() {
        let decision = ContextDetector.detectTerminalDecision(
            bundleID: "com.apple.Terminal",
            haystack: "macToolBox",
            text: "",
            regionText: "Welcome to Codex\nHow can I help?"
        )

        XCTAssertEqual(decision?.kind, .terminalAgent)
        XCTAssertEqual(decision?.lang, .chinese)
    }

    func testTerminalContextDefaultsToEnglish() {
        XCTAssertEqual(
            ContextDetector.detectTerminalContext(
                haystack: "AXGroup Integrated Terminal zsh",
                text: "project % git status"
            ),
            .english
        )
    }

    func testTerminalRecognizedByBundleIDWithoutMetadata() {
        XCTAssertEqual(
            ContextDetector.detectTerminalContext(
                bundleID: "com.apple.Terminal",
                haystack: "macToolBox",
                text: "macToolBox % "
            ),
            .english
        )
    }

    func testTerminalPromptFallbackForUnknownTerminal() {
        XCTAssertEqual(
            ContextDetector.detectTerminalContext(
                bundleID: "com.example.TerminalLike",
                haystack: "Project",
                text: "~/proj ❯ "
            ),
            .english
        )
    }

    func testScrollbackChineseIgnoredInRecognizedTerminal() {
        XCTAssertEqual(
            ContextDetector.detectTerminalContext(
                bundleID: "com.apple.Terminal",
                haystack: "macToolBox",
                text: "这是上一条中文输出\nmacToolBox % "
            ),
            .english
        )
    }

    func testAgentInCurrentLineUsesChinese() {
        XCTAssertEqual(
            ContextDetector.detectTerminalContext(
                bundleID: "com.apple.Terminal",
                haystack: "macToolBox",
                text: "macToolBox % codex --help"
            ),
            .chinese
        )
    }

    func testAgentInScrollbackRevertsToEnglish() {
        XCTAssertEqual(
            ContextDetector.detectTerminalContext(
                bundleID: "com.apple.Terminal",
                haystack: "macToolBox",
                text: "$ codex\n这是历史中文输出\nmacToolBox % "
            ),
            .english
        )
    }

    func testEditorHostPromptDoesNotForceTerminal() {
        XCTAssertNil(
            ContextDetector.detectTerminalContext(
                bundleID: "com.microsoft.VSCode",
                haystack: "report.md — Edited",
                text: "完成度 100 % "
            )
        )
    }

    func testVSCodeIntegratedTerminalViaMetadata() {
        XCTAssertEqual(
            ContextDetector.detectTerminalContext(
                bundleID: "com.microsoft.VSCode",
                haystack: "AXGroup Integrated Terminal zsh",
                text: "repo % "
            ),
            .english
        )
    }

    func testTerminalContextWithAgentKeywordUsesChinese() {
        XCTAssertEqual(
            ContextDetector.detectTerminalContext(
                haystack: "Terminal — Visual Studio Code",
                text: "$ opencode\n$ codex"
            ),
            .chinese
        )
        XCTAssertEqual(
            ContextDetector.detectTerminalContext(
                haystack: "Claude Code - terminal",
                text: "$ npm test"
            ),
            .chinese
        )
    }

    func testNonTerminalContextIsNotForced() {
        XCTAssertNil(
            ContextDetector.detectTerminalContext(
                haystack: "Chat input",
                text: "你好，帮我写一段说明"
            )
        )
    }

    func testEditorWithShellLikeTextIsNotTreatedAsTerminal() {
        // 回归：编辑器/文档里的 Markdown 标题、`$ npm`、Python 注释等不得被误判为终端而强制英文。
        XCTAssertNil(
            ContextDetector.detectTerminalContext(
                haystack: "README.md — Editor",
                text: "# Introduction\n$ npm install\n# a comment"
            )
        )
    }

    func testKeywordHaystackKeepsTitleFirstTruncatesAndDedupes() {
        let longTitle = String(repeating: "a", count: 600)
        let haystack = ContextDetector.keywordHaystack(
            windowTitle: longTitle,
            elementShortTexts: [
                ["codex", "codex", "assistant"],
                ["terminal", "codex"],
            ]
        )

        let lines = haystack.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first?.count, 500)
        XCTAssertEqual(lines.dropFirst(), ["codex", "assistant", "terminal"])
    }

    func testKeywordHaystackSkipsBlankEntries() {
        let haystack = ContextDetector.keywordHaystack(
            windowTitle: "  ",
            elementShortTexts: [
                ["", "   ", "\n"],
                ["codex"],
            ]
        )

        XCTAssertEqual(haystack, "codex")
    }

    func testAXCapabilityTreatsEmptyElectronTreeAsBlackBox() {
        XCTAssertEqual(
            ContextDetector.axCapability(
                bundleID: "com.openai.codex",
                elementNodes: [],
                cursorText: nil,
                regionText: nil,
                windowText: nil,
                hasElement: false
            ),
            .blackBox
        )
    }

    func testAXCapabilityTreatsTextInputAsComponentVisible() {
        XCTAssertEqual(
            ContextDetector.axCapability(
                bundleID: "com.openai.codex",
                elementNodes: [
                    ContextDetector.FocusRegionNode(role: "AXTextArea", shortTexts: ["Message"]),
                ],
                cursorText: nil,
                regionText: nil,
                windowText: nil,
                hasElement: true
            ),
            .componentVisible
        )
    }

    func testAXCapabilityTreatsWindowTextAsTextVisible() {
        XCTAssertEqual(
            ContextDetector.axCapability(
                bundleID: "com.openai.codex",
                elementNodes: [],
                cursorText: nil,
                regionText: nil,
                windowText: "project % ",
                hasElement: false
            ),
            .textVisible
        )
    }

    func testFocusRegionSelectsNearestContentContainer() {
        let nodes = [
            ContextDetector.FocusRegionNode(role: "AXStaticText", shortTexts: ["message"]),
            ContextDetector.FocusRegionNode(role: "AXGroup", shortTexts: ["chat area"]),
            ContextDetector.FocusRegionNode(role: "AXWindow", shortTexts: ["window"]),
        ]

        XCTAssertEqual(ContextDetector.focusRegionIndex(in: nodes), 1)
    }

    func testFocusRegionFallsBackToTextInputBeforeWindow() {
        let nodes = [
            ContextDetector.FocusRegionNode(role: "AXTextArea", shortTexts: ["editor"]),
            ContextDetector.FocusRegionNode(role: "AXWindow", shortTexts: ["window"]),
        ]

        XCTAssertEqual(ContextDetector.focusRegionIndex(in: nodes), 0)
    }

    func testFocusRegionRejectsChromeAndWindowOnlyNodes() {
        XCTAssertNil(ContextDetector.focusRegionIndex(in: [
            ContextDetector.FocusRegionNode(role: "AXWindow", shortTexts: ["window"]),
        ]))

        XCTAssertNil(ContextDetector.focusRegionIndex(in: [
            ContextDetector.FocusRegionNode(role: "AXButton", shortTexts: ["Run"]),
            ContextDetector.FocusRegionNode(role: "AXToolbar", shortTexts: ["toolbar"]),
            ContextDetector.FocusRegionNode(role: "AXWindow", shortTexts: ["window"]),
        ]))
    }

    func testDetectLanguageUsesRegionBeforeWindowAndTitle() {
        XCTAssertEqual(
            ContextDetector.detectLanguage(
                cursorText: nil,
                regionText: "你好，这是当前聊天区域",
                windowText: "English text from another panel",
                windowTitle: "English title"
            ),
            .chinese
        )
    }

    func testDetectLanguageFallsBackWhenRegionTextIsInsufficient() {
        XCTAssertEqual(
            ContextDetector.detectLanguage(
                cursorText: nil,
                regionText: "1",
                windowText: "English text from fallback window",
                windowTitle: "中文标题"
            ),
            .english
        )
    }

    func testDetectLanguageKeepsCursorTextFirst() {
        XCTAssertEqual(
            ContextDetector.detectLanguage(
                cursorText: "Current cursor text is English",
                regionText: "你好，这是当前区域",
                windowText: "你好，这是整个窗口",
                windowTitle: "中文标题"
            ),
            .english
        )
    }

    func testKeywordHaystackStopsAtFocusRegionBoundary() {
        let haystack = ContextDetector.keywordHaystack(
            windowTitle: "Project",
            elementNodes: [
                ContextDetector.FocusRegionNode(role: "AXStaticText", shortTexts: ["message"]),
                ContextDetector.FocusRegionNode(role: "AXGroup", shortTexts: ["chat-panel"]),
                ContextDetector.FocusRegionNode(role: "AXSplitGroup", shortTexts: ["terminal-panel"]),
                ContextDetector.FocusRegionNode(role: "AXWindow", shortTexts: ["window"]),
            ]
        )

        XCTAssertTrue(haystack.contains("Project"))
        XCTAssertTrue(haystack.contains("chat-panel"))
        XCTAssertFalse(haystack.contains("terminal-panel"))
    }

    func testKeywordMatcherUsesFirstMatchingRule() {
        let rules = [
            KeywordRule(keyword: "terminal", lang: .english),
            KeywordRule(keyword: "codex", lang: .chinese),
        ]

        XCTAssertEqual(
            KeywordMatcher.match(in: "inside terminal with codex", rules: rules),
            .english
        )
    }

    func testKeywordMatcherReturnsNilWhenNoRuleMatches() {
        let rules = [
            KeywordRule(keyword: "codex", lang: .chinese),
        ]

        XCTAssertNil(KeywordMatcher.match(in: "plain editor", rules: rules))
    }
}
