import AppKit
import ApplicationServices
import CoreGraphics

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

    // MARK: 屏幕录制（OCR 兜底所需）

    static var screenCaptureTrusted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestScreenCapturePrompt() {
        // 首次调用触发系统「屏幕录制」授权弹窗；被拒后只能去系统设置打开并重启 App
        CGRequestScreenCaptureAccess()
    }

    static func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenRecording")!
        NSWorkspace.shared.open(url)
    }
}
