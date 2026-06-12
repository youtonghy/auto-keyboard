import AppKit
import ApplicationServices

@MainActor
enum Permissions {
    static var axTrusted: Bool {
        AXIsProcessTrusted()
    }

    static func requestAXPrompt() {
        // kAXTrustedCheckOptionPrompt 常量在 Swift 6 并发检查下不可直接引用，使用其字面值
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
