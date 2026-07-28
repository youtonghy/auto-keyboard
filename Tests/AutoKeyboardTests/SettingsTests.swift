import XCTest

@testable import AutoKeyboard

final class SettingsTests: XCTestCase {
    func testDecodingOldSettingsDefaultsToMemoryMode() throws {
        let data = Data("""
        {
          "enabled": true,
          "englishSourceID": "com.apple.keylayout.ABC",
          "chineseSourceID": "com.apple.inputmethod.SCIM.ITABC",
          "appRules": []
        }
        """.utf8)

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.defaultMode, .memory)
        XCTAssertTrue(settings.smartLearningEnabled)
        XCTAssertEqual(settings.smartContext.terminalBundleIDs, SmartContextSettings.defaultTerminalBundleIDs)
    }

    func testDecodingDefaultMode() throws {
        let data = Data("""
        {
          "enabled": true,
          "defaultMode": "smart",
          "appRules": []
        }
        """.utf8)

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.defaultMode, .smart)
    }

    func testDecodingSmartContextSettings() throws {
        let data = Data("""
        {
          "enabled": true,
          "smartContext": {
            "terminalBundleIDs": ["com.example.Terminal"],
            "multiContextHostBundleIDs": ["com.example.Host"],
            "terminalAgentKeywords": ["agent"],
            "chatSemanticKeywords": ["compose"]
          },
          "appRules": []
        }
        """.utf8)

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.smartContext.terminalBundleIDs, ["com.example.Terminal"])
        XCTAssertEqual(settings.smartContext.multiContextHostBundleIDs, ["com.example.Host"])
        XCTAssertEqual(settings.smartContext.terminalAgentKeywords, ["agent"])
        XCTAssertEqual(settings.smartContext.chatSemanticKeywords, ["compose"])
    }
}
