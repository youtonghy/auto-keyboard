import AppKit
import ApplicationServices

private func axObserverCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    nonisolated(unsafe) let ref = refcon
    let name = notification as String
    // 回调源在主 RunLoop 上注册，必然在主线程执行
    MainActor.assumeIsolated {
        let tracker = Unmanaged<FocusTracker>.fromOpaque(ref).takeUnretainedValue()
        tracker.handleAXNotification(name)
    }
}

@MainActor
final class FocusTracker: ObservableObject {
    struct Focus {
        let bundleID: String
        let appName: String
        let processID: pid_t?
        let window: AXUIElement?
        let windowTitle: String
        let element: AXUIElement?

        var key: WindowKey {
            WindowKey(bundleID: bundleID, window: window, title: windowTitle)
        }
    }

    enum Trigger {
        case appActivated
        case windowChanged
        case elementChanged
        case titleChanged
        case selectionChanged
    }

    @Published private(set) var lastFocus: Focus?
    private(set) var isSelfFrontmost = false

    var onFocusEvent: ((Focus, Trigger) -> Void)?

    private var observer: AXObserver?
    private var appElement: AXUIElement?
    private var observedBundleID = ""
    private var observedAppName = ""

    private static let subscribedNotifications: [String] = [
        kAXMainWindowChangedNotification as String,
        kAXFocusedWindowChangedNotification as String,
        kAXFocusedUIElementChangedNotification as String,
        kAXTitleChangedNotification as String,
        kAXSelectedTextChangedNotification as String,
    ]

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        if let app = NSWorkspace.shared.frontmostApplication {
            attach(to: app)
            emit(.appActivated)
        }
    }

    /// 权限授予后重新挂载当前前台应用
    func reattachFrontmost() {
        if let app = NSWorkspace.shared.frontmostApplication,
           app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            attach(to: app)
            emit(.appActivated)
        }
    }

    @objc private func appActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            isSelfFrontmost = true
            return
        }
        isSelfFrontmost = false
        attach(to: app)
        emit(.appActivated)
    }

    func handleAXNotification(_ name: String) {
        switch name {
        case kAXMainWindowChangedNotification,
             kAXFocusedWindowChangedNotification:
            emit(.windowChanged)
        case kAXFocusedUIElementChangedNotification:
            emit(.elementChanged)
        case kAXTitleChangedNotification:
            emit(.titleChanged)
        case kAXSelectedTextChangedNotification:
            emit(.selectionChanged)
        default:
            break
        }
    }

    private func attach(to app: NSRunningApplication) {
        detach()
        let pid = app.processIdentifier
        observedBundleID = app.bundleIdentifier ?? "pid.\(pid)"
        observedAppName = app.localizedName ?? observedBundleID

        let appEl = AXUIElementCreateApplication(pid)
        appElement = appEl
        AX.setMessagingTimeout(appEl)
        // 让 Electron 应用暴露辅助功能树
        AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        var obs: AXObserver?
        guard AXObserverCreate(pid, axObserverCallback, &obs) == .success, let obs else { return }
        observer = obs
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.subscribedNotifications {
            AXObserverAddNotification(obs, appEl, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
    }

    private func detach() {
        if let obs = observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        observer = nil
        appElement = nil
    }

    private func emit(_ trigger: Trigger) {
        let focus = snapshot()
        lastFocus = focus
        onFocusEvent?(focus, trigger)
    }

    private func snapshot() -> Focus {
        var window: AXUIElement?
        var title = ""
        var element: AXUIElement?
        if let appEl = appElement {
            window = AX.copyElement(appEl, kAXFocusedWindowAttribute)
            if let window {
                title = AX.copyString(window, kAXTitleAttribute) ?? ""
            }
            element = AX.copyElement(appEl, kAXFocusedUIElementAttribute)
        }
        return Focus(
            bundleID: observedBundleID,
            appName: observedAppName,
            processID: AX.pid(of: appElement),
            window: window,
            windowTitle: title,
            element: element
        )
    }
}

// MARK: - AX 属性读取工具

enum AX {
    static let messagingTimeout: Float = 0.25

    static func setMessagingTimeout(_ el: AXUIElement) {
        AXUIElementSetMessagingTimeout(el, messagingTimeout)
    }

    static func pid(of el: AXUIElement?) -> pid_t? {
        guard let el else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(el, &pid) == .success else { return nil }
        return pid
    }

    static func copyElement(_ el: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    static func copyString(_ el: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func copyStringLike(_ el: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attribute as CFString, &value) == .success,
              let value
        else { return nil }
        if let string = value as? String {
            return string
        }
        if let attributed = value as? NSAttributedString {
            return attributed.string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    static func copyStringLikes(_ el: AXUIElement, _ attributes: [String]) -> [String: String] {
        var values: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(
            el,
            attributes as CFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0),
            &values
        )
        if error == .success, let array = values as? [AnyObject] {
            var result: [String: String] = [:]
            for (index, rawValue) in array.enumerated() where index < attributes.count {
                guard CFGetTypeID(rawValue) != CFNullGetTypeID(),
                      let string = stringLike(rawValue)
                else { continue }
                result[attributes[index]] = string
            }
            return result
        }
        return Dictionary(uniqueKeysWithValues: attributes.compactMap { attribute in
            copyStringLike(el, attribute).map { (attribute, $0) }
        })
    }

    static func copyInt(_ el: AXUIElement, _ attribute: String) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attribute as CFString, &value) == .success else { return nil }
        return value as? Int
    }

    static func copyChildren(_ el: AXUIElement) -> [AXUIElement]? {
        let attributes = [
            kAXChildrenAttribute as String,
            "AXChildrenInNavigationOrder",
            "AXContents",
            "AXRows",
        ]
        var children: [AXUIElement] = []
        var seen = Set<CFHashCode>()

        for attribute in attributes {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, attribute as CFString, &value) == .success,
                  let array = value as? [AnyObject]
            else { continue }
            for item in array where CFGetTypeID(item) == AXUIElementGetTypeID() {
                let child = item as! AXUIElement
                let hash = CFHash(child)
                guard seen.insert(hash).inserted else { continue }
                children.append(child)
            }
        }

        return children.isEmpty ? nil : children
    }

    static func copyRange(_ el: AXUIElement, _ attribute: String) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue((value as! AXValue), .cfRange, &range) else { return nil }
        return range
    }

    static func copyStringForRange(_ el: AXUIElement, _ range: CFRange) -> String? {
        var r = range
        guard let rangeValue = AXValueCreate(.cfRange, &r) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            el, kAXStringForRangeParameterizedAttribute as CFString, rangeValue, &value
        ) == .success else { return nil }
        return value as? String
    }

    private static func stringLike(_ value: AnyObject) -> String? {
        if let string = value as? String {
            return string
        }
        if let attributed = value as? NSAttributedString {
            return attributed.string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }
}
