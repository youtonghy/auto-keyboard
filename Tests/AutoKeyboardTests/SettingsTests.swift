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
}
