import XCTest

@testable import AutoKeyboard

final class WindowKeyTests: XCTestCase {
    func testTitleFallbackIsStable() {
        let first = WindowKey(bundleID: "com.example.app", window: nil, title: "Draft").raw
        let second = WindowKey(bundleID: "com.example.app", window: nil, title: "Draft").raw

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.hasPrefix("com.example.app#t"))
    }

    func testDifferentTitlesProduceDifferentFallbacks() {
        let first = WindowKey(bundleID: "com.example.app", window: nil, title: "Draft").raw
        let second = WindowKey(bundleID: "com.example.app", window: nil, title: "Inbox").raw

        XCTAssertNotEqual(first, second)
    }
}
