import XCTest

@testable import AutoKeyboard

/// 指纹 v3 测试：核心诉求是「稳定 + 通用化 + 上下文分桶」——
/// 同一逻辑组件跨多次聚焦、跨网页重渲染都得稳定；同类组件在 App 内通用化。
final class SmartLearningKeyBuilderTests: XCTestCase {
    func testSameAppAndComponentProduceSameKey() {
        let nodes = [
            SmartLearningKeyBuilder.Node(role: "AXTextArea", identifier: "message-input", placeholder: "Message"),
        ]

        XCTAssertEqual(
            SmartLearningKeyBuilder.key(bundleID: "com.example.app", nodes: nodes),
            SmartLearningKeyBuilder.key(bundleID: "com.example.app", nodes: nodes)
        )
    }

    func testDifferentAppsProduceDifferentKeys() {
        let nodes = [SmartLearningKeyBuilder.Node(role: "AXTextArea", placeholder: "Message")]

        XCTAssertNotEqual(
            SmartLearningKeyBuilder.key(bundleID: "com.example.one", nodes: nodes),
            SmartLearningKeyBuilder.key(bundleID: "com.example.two", nodes: nodes)
        )
    }

    /// DOM identifier 常是 React/MUI 自动生成、每次重渲染都变——新设计不再用它，
    /// 所以 identifier 抖动不应改变指纹（这正是“每次指纹都变”的根因）。
    func testIdentifierVolatilityDoesNotChangeKey() {
        let rendered1 = [SmartLearningKeyBuilder.Node(role: "AXTextArea", identifier: ":r1:", placeholder: "Message")]
        let rendered2 = [SmartLearningKeyBuilder.Node(role: "AXTextArea", identifier: ":r9:", placeholder: "Message")]

        XCTAssertEqual(
            SmartLearningKeyBuilder.key(bundleID: "com.example.app", nodes: rendered1),
            SmartLearningKeyBuilder.key(bundleID: "com.example.app", nodes: rendered2)
        )
    }

    /// 祖先结构链（多/少一层 wrapper group）不应影响指纹——网页里这层结构最常抖动。
    func testAncestorChainVolatilityDoesNotChangeKey() {
        let withWrapper = [
            SmartLearningKeyBuilder.Node(role: "AXTextArea", placeholder: "Message"),
            SmartLearningKeyBuilder.Node(role: "AXGroup"),
            SmartLearningKeyBuilder.Node(role: "AXWebArea"),
        ]
        let withoutWrapper = [
            SmartLearningKeyBuilder.Node(role: "AXTextArea", placeholder: "Message"),
            SmartLearningKeyBuilder.Node(role: "AXWebArea"),
        ]

        XCTAssertEqual(
            SmartLearningKeyBuilder.key(bundleID: "com.example.app", nodes: withWrapper),
            SmartLearningKeyBuilder.key(bundleID: "com.example.app", nodes: withoutWrapper)
        )
    }

    func testDifferentLabelProducesDifferentKey() {
        let message = [SmartLearningKeyBuilder.Node(role: "AXTextArea", placeholder: "Message")]
        let search = [SmartLearningKeyBuilder.Node(role: "AXTextArea", placeholder: "Search")]

        XCTAssertNotEqual(
            SmartLearningKeyBuilder.key(bundleID: "com.example.app", nodes: message),
            SmartLearningKeyBuilder.key(bundleID: "com.example.app", nodes: search)
        )
    }

    func testDifferentRoleProducesDifferentKey() {
        let area = [SmartLearningKeyBuilder.Node(role: "AXTextArea", placeholder: "X")]
        let field = [SmartLearningKeyBuilder.Node(role: "AXTextField", placeholder: "X")]

        XCTAssertNotEqual(
            SmartLearningKeyBuilder.key(bundleID: "com.example.app", nodes: area),
            SmartLearningKeyBuilder.key(bundleID: "com.example.app", nodes: field)
        )
    }

    func testDifferentContextKindProducesDifferentKey() {
        let nodes = [SmartLearningKeyBuilder.Node(role: "AXTextArea", placeholder: "Message")]

        XCTAssertNotEqual(
            SmartLearningKeyBuilder.key(
                bundleID: "com.openai.codex",
                nodes: nodes,
                contextKind: .assistantChatInput
            ),
            SmartLearningKeyBuilder.key(
                bundleID: "com.openai.codex",
                nodes: nodes,
                contextKind: .terminalShell
            )
        )
    }

    /// 即使没有标签（很多原生输入框没有 placeholder/aria-label），只要有 role 也能产出指纹，
    /// 使“同一种无标签元素”也能被学习（通用化），而不是像旧版那样返回 nil 永不学习。
    func testUnlabeledRoleStillProducesKey() {
        XCTAssertNotNil(SmartLearningKeyBuilder.key(
            bundleID: "com.example.app",
            nodes: [SmartLearningKeyBuilder.Node(role: "AXTextArea")]
        ))
    }

    func testMissingFocusedElementUsesContextFallbackKey() {
        XCTAssertNotNil(SmartLearningKeyBuilder.key(
            bundleID: "com.openai.codex",
            element: nil,
            contextKind: .assistantChatInput
        ))
        XCTAssertNotEqual(
            SmartLearningKeyBuilder.key(
                bundleID: "com.openai.codex",
                element: nil,
                contextKind: .assistantChatInput
            ),
            SmartLearningKeyBuilder.key(
                bundleID: "com.openai.codex",
                element: nil,
                contextKind: .terminalShell
            )
        )
    }

    func testMissingFocusedElementUnknownContextDoesNotLearn() {
        XCTAssertNil(SmartLearningKeyBuilder.key(
            bundleID: "com.openai.codex",
            element: nil,
            contextKind: .unknown
        ))
    }

    func testEmptyRoleProducesNil() {
        XCTAssertNil(SmartLearningKeyBuilder.key(
            bundleID: "com.example.app",
            nodes: [SmartLearningKeyBuilder.Node(role: "")]
        ))
    }

    /// 标签可来自祖先容器（焦点元素自身无标签时），且只取文本、不带位置——保证稳定。
    func testLabelResolvedFromAncestor() {
        let focusOnlyRole = [SmartLearningKeyBuilder.Node(role: "AXTextArea")]
        let withAncestorLabel = [
            SmartLearningKeyBuilder.Node(role: "AXTextArea"),
            SmartLearningKeyBuilder.Node(role: "AXGroup", title: "Chat"),
        ]

        XCTAssertNotNil(SmartLearningKeyBuilder.key(bundleID: "com.example.app", nodes: withAncestorLabel))
        XCTAssertNotEqual(
            SmartLearningKeyBuilder.key(bundleID: "com.example.app", nodes: focusOnlyRole),
            SmartLearningKeyBuilder.key(bundleID: "com.example.app", nodes: withAncestorLabel)
        )
    }

    func testRawTextIsNotExposedInDigest() throws {
        let secret = "private draft text should not be stored"
        let key = try XCTUnwrap(SmartLearningKeyBuilder.key(
            bundleID: "com.example.app",
            nodes: [SmartLearningKeyBuilder.Node(role: "AXTextArea", placeholder: secret)]
        ))

        XCTAssertFalse(key.rawValue.contains(secret))
        XCTAssertTrue(key.rawValue.hasPrefix("smart-component:v3:"))
    }
}
