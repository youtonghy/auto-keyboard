import AppKit
import Carbon.HIToolbox

struct InputSource: Identifiable, Hashable {
    let id: String
    let localizedName: String
    let isChineseCapable: Bool
}

@MainActor
protocol InputSourceManaging: AnyObject {
    var currentID: String { get }
    func select(id: String) async -> Bool
}

@MainActor
final class InputSourceManager: ObservableObject, InputSourceManaging {
    @Published private(set) var available: [InputSource] = []
    @Published private(set) var currentID: String = ""

    /// 用户手动切换输入源（非本程序触发）时回调
    var onUserChange: ((String) -> Void)?

    private var expectedID: String?
    private var suppressUntil: Date = .distantPast

    init() {
        refreshAvailable()
        currentID = Self.readCurrentID() ?? ""
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(systemSourceChanged(_:)),
            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil
        )
    }

    func name(of sourceID: String) -> String {
        available.first { $0.id == sourceID }?.localizedName ?? sourceID
    }

    func refreshAvailable() {
        let filter = [kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource] as CFDictionary
        guard let cfList = TISCreateInputSourceList(filter, false)?.takeRetainedValue() else { return }
        let list = cfList as! [TISInputSource]
        available = list.compactMap { src in
            guard Self.boolProperty(src, kTISPropertyInputSourceIsSelectCapable),
                  Self.boolProperty(src, kTISPropertyInputSourceIsEnabled),
                  let id = Self.stringProperty(src, kTISPropertyInputSourceID)
            else { return nil }
            let name = Self.stringProperty(src, kTISPropertyLocalizedName) ?? id
            let langs = Self.languages(src)
            let zh = langs.contains { $0.hasPrefix("zh") }
            return InputSource(id: id, localizedName: name, isChineseCapable: zh)
        }
    }

    /// 切换输入源，带校验重试。返回是否成功。
    func select(id: String) async -> Bool {
        if currentID == id { return true }
        guard let target = Self.findSource(id: id) else { return false }
        expectedID = id
        suppressUntil = Date().addingTimeInterval(1.0)
        for _ in 0..<3 {
            TISSelectInputSource(target)
            try? await Task.sleep(for: .milliseconds(60))
            if Self.readCurrentID() == id {
                currentID = id
                return true
            }
        }
        return false
    }

    func guessDefaults() -> (english: String?, chinese: String?) {
        let english = available.first { $0.id == "com.apple.keylayout.ABC" }?.id
            ?? available.first { $0.id.hasPrefix("com.apple.keylayout.") }?.id
        let chinese = available.first { $0.isChineseCapable }?.id
        return (english, chinese)
    }

    @objc private func systemSourceChanged(_ note: Notification) {
        let newID = Self.readCurrentID() ?? ""
        let oldID = currentID
        currentID = newID
        if let expected = expectedID, expected == newID, Date() < suppressUntil {
            return
        }
        if newID != oldID, !newID.isEmpty {
            onUserChange?(newID)
        }
    }

    // MARK: - TIS helpers

    nonisolated private static func readCurrentID() -> String? {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return stringProperty(src, kTISPropertyInputSourceID)
    }

    nonisolated private static func findSource(id: String) -> TISInputSource? {
        let filter = [kTISPropertyInputSourceID: id] as CFDictionary
        guard let cfList = TISCreateInputSourceList(filter, false)?.takeRetainedValue() else { return nil }
        return (cfList as! [TISInputSource]).first
    }

    nonisolated private static func stringProperty(_ src: TISInputSource, _ key: CFString) -> String? {
        guard let ptr = TISGetInputSourceProperty(src, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    nonisolated private static func boolProperty(_ src: TISInputSource, _ key: CFString) -> Bool {
        guard let ptr = TISGetInputSourceProperty(src, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(ptr).takeUnretainedValue())
    }

    nonisolated private static func languages(_ src: TISInputSource) -> [String] {
        guard let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceLanguages) else { return [] }
        let cfArr = Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue()
        return (cfArr as? [String]) ?? []
    }
}
