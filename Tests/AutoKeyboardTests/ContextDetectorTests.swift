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
