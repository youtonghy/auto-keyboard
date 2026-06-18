import AppKit
import ApplicationServices
import os

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
    private let logger = Logger(subsystem: "com.autokeyboard", category: "focus")

    struct Focus {
        let bundleID: String
        let appName: String
        let window: AXUIElement?
        let windowTitle: String
        let element: AXUIElement?
        let hitElement: AXUIElement?
        let focusPoint: CGPoint?

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
        case valueChanged
        case mouseDown
    }

    @Published private(set) var lastFocus: Focus?
    private(set) var isSelfFrontmost = false

    var onFocusEvent: ((Focus, Trigger) -> Void)?
    var onDebugLog: ((String) -> Void)?

    private var observer: AXObserver?
    private var appElement: AXUIElement?
    private var observedBundleID = ""
    private var observedAppName = ""
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var lastMouseDownPoint: CGPoint?
    private var lastMouseDownAt: Date?
    private var mouseDownEmitTask: Task<Void, Never>?
    private var mouseDownSequence = 0
    private static let clickIntentTTL: TimeInterval = 0.9

    private static let subscribedNotifications: [String] = [
        kAXMainWindowChangedNotification as String,
        kAXFocusedWindowChangedNotification as String,
        kAXFocusedUIElementChangedNotification as String,
        kAXTitleChangedNotification as String,
        kAXSelectedTextChangedNotification as String,
    ]

    func start() {
        installMouseMonitors()
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
        logger.debug("ax-notify \(name, privacy: .public)")
        onDebugLog?("ax-notify \(name)")
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
        case kAXValueChangedNotification:
            emit(.valueChanged)
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
        // 让 Electron 应用暴露辅助功能树
        AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        var obs: AXObserver?
        guard AXObserverCreate(pid, axObserverCallback, &obs) == .success, let obs else { return }
        observer = obs
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.subscribedNotifications {
            AXObserverAddNotification(obs, appEl, name as CFString, refcon)
        }
        onDebugLog?("attach \(observedBundleID)")
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
        let mouseDown = freshMouseDownContext()
        let focus = snapshot(mouseDownPoint: mouseDown?.point)
        lastFocus = focus
        let hitRole = focus.hitElement.flatMap { AX.copyString($0, kAXRoleAttribute as String) } ?? "nil"
        logger.debug(
            "snapshot trig=\(String(describing: trigger), privacy: .public) bundle=\(focus.bundleID, privacy: .public) title=\(focus.windowTitle, privacy: .public) focusPoint=\(String(describing: focus.focusPoint), privacy: .public) hitRole=\(hitRole, privacy: .public) hasHit=\(focus.hitElement != nil, privacy: .public)"
        )
        let clickText = mouseDown.map { "point=\(AX.formatPoint($0.point)) ageMs=\($0.ageMs)" } ?? "point=nil"
        onDebugLog?("snapshot trig=\(trigger) bundle=\(focus.bundleID) title=\"\(focus.windowTitle)\" click=\(clickText) element=\(AX.debugSummary(focus.element)) hit=\(AX.debugSummary(focus.hitElement))")
        onFocusEvent?(focus, trigger)
    }

    private func snapshot(mouseDownPoint: CGPoint? = nil) -> Focus {
        var window: AXUIElement?
        var title = ""
        var element: AXUIElement?
        var hitElement: AXUIElement?
        let focusPoint = mouseDownPoint ?? freshMouseDownContext()?.point
        if let appEl = appElement {
            window = AX.copyElement(appEl, kAXFocusedWindowAttribute)
            if let window {
                title = AX.copyString(window, kAXTitleAttribute) ?? ""
            }
            element = AX.copyElement(appEl, kAXFocusedUIElementAttribute)
            if let focusPoint {
                hitElement = AX.elementNearPosition(appEl, focusPoint) { [weak self] message in
                    self?.onDebugLog?("hit-test \(message)")
                }
            }
        }
        return Focus(
            bundleID: observedBundleID,
            appName: observedAppName,
            window: window,
            windowTitle: title,
            element: element,
            hitElement: hitElement,
            focusPoint: focusPoint
        )
    }

    private func installMouseMonitors() {
        guard globalMouseMonitor == nil, localMouseMonitor == nil else { return }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            self?.recordMouseDown(source: "global")
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            self?.recordMouseDown(source: "local", event: event)
            return event
        }
    }

    private func removeMouseMonitors() {
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
        }
        globalMouseMonitor = nil
        localMouseMonitor = nil
    }

    private func recordMouseDown(source: String, event: NSEvent? = nil) {
        let point = NSEvent.mouseLocation
        lastMouseDownPoint = point
        lastMouseDownAt = Date()
        mouseDownSequence += 1
        let sequence = mouseDownSequence
        let windowPoint = event.map { AX.formatPoint($0.locationInWindow) } ?? "nil"
        let cgPoint = event?.cgEvent.map { AX.formatPoint($0.location) } ?? "nil"
        let cgUnflipped = event?.cgEvent.map { AX.formatPoint($0.unflippedLocation) } ?? "nil"
        onDebugLog?("mouse-down source=\(source) seq=\(sequence) point=\(AX.formatPoint(point)) window=\(windowPoint) cg=\(cgPoint) cgUnflipped=\(cgUnflipped)")
        mouseDownEmitTask?.cancel()
        mouseDownEmitTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard let self else { return }
            await MainActor.run {
                guard self.mouseDownSequence == sequence,
                      self.freshMouseDownContext() != nil
                else { return }
                self.emit(.mouseDown)
            }
        }
    }

    private func freshMouseDownContext() -> (point: CGPoint, ageMs: Int)? {
        guard let point = lastMouseDownPoint,
              let at = lastMouseDownAt,
              Date().timeIntervalSince(at) <= Self.clickIntentTTL
        else { return nil }
        return (point: point, ageMs: Int((Date().timeIntervalSince(at) * 1000).rounded()))
    }
}

// MARK: - AX 属性读取工具

enum AX {
    static func formatPoint(_ point: CGPoint) -> String {
        String(format: "(%.1f,%.1f)", Double(point.x), Double(point.y))
    }

    static func formatRect(_ rect: CGRect) -> String {
        String(format: "(%.1f,%.1f,%.1f,%.1f)", Double(rect.origin.x), Double(rect.origin.y), Double(rect.size.width), Double(rect.size.height))
    }

    static func copyElement(_ el: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    static func elementAtPosition(_ app: AXUIElement, _ point: CGPoint) -> AXUIElement? {
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &element) == .success else {
            return nil
        }
        return element
    }

    static func elementNearPosition(_ app: AXUIElement, _ point: CGPoint, trace: ((String) -> Void)? = nil) -> AXUIElement? {
        let offsets: [CGPoint] = [
            .zero,
            CGPoint(x: 0, y: -18),
            CGPoint(x: 0, y: 18),
            CGPoint(x: -18, y: 0),
            CGPoint(x: 18, y: 0),
            CGPoint(x: 0, y: -42),
            CGPoint(x: 0, y: 42),
            CGPoint(x: -36, y: 0),
            CGPoint(x: 36, y: 0),
            CGPoint(x: 0, y: -72),
            CGPoint(x: 0, y: 72),
        ]
        var best: AXUIElement?
        var bestRaw: AXUIElement?
        var bestProbe: CGPoint?
        var bestScore = Int.min
        var bestDistance = CGFloat.greatestFiniteMagnitude

        for delta in offsets {
            let probe = CGPoint(x: point.x + delta.x, y: point.y + delta.y)
            guard let candidate = elementAtPosition(app, probe) else { continue }
            let refined = refineHitElement(candidate, at: probe) ?? candidate
            let score = hitScore(of: refined)
            let distance = abs(delta.x) + abs(delta.y)
            if score > bestScore || (score == bestScore && distance < bestDistance) {
                best = refined
                bestRaw = candidate
                bestProbe = probe
                bestScore = score
                bestDistance = distance
            }
        }

        if let best, let bestRaw, let bestProbe {
            trace?("point=\(formatPoint(point)) probe=\(formatPoint(bestProbe)) raw=\(debugSummary(bestRaw)) refined=\(debugSummary(best)) score=\(bestScore) probeDelta=\(Int(bestDistance))")
        } else {
            trace?("point=\(formatPoint(point)) probe=nil result=nil")
        }
        return best
    }

    static func refineHitElement(_ element: AXUIElement, at point: CGPoint) -> AXUIElement? {
        guard let best = deepHitElement(from: element, at: point) else { return nil }
        return CFEqual(best, element) ? nil : best
    }

    private static func deepHitElement(from root: AXUIElement, at point: CGPoint, maxDepth: Int = 5) -> AXUIElement? {
        let searchSlop: CGFloat = 96
        let searchRect = CGRect(x: point.x - searchSlop, y: point.y - searchSlop, width: searchSlop * 2, height: searchSlop * 2)
        guard let rootBounds = bounds(of: root), rootBounds.intersects(searchRect) else { return nil }

        var best = root
        var bestScore = hitScore(of: root)
        var bestArea = area(of: rootBounds)
        var bestDistance = distance(of: rootBounds, to: point)

        func walk(_ element: AXUIElement, depth: Int) {
            guard depth < maxDepth, let children = copyChildren(element) else { return }
            for child in children {
                guard let childBounds = bounds(of: child), childBounds.intersects(searchRect) else { continue }
                let score = hitScore(of: child)
                let area = area(of: childBounds)
                let distance = distance(of: childBounds, to: point)
                if score > bestScore || (score == bestScore && (distance < bestDistance || (distance == bestDistance && area < bestArea))) {
                    best = child
                    bestScore = score
                    bestArea = area
                    bestDistance = distance
                }
                walk(child, depth: depth + 1)
            }
        }

        walk(root, depth: 0)
        return best
    }

    private static func bounds(of el: AXUIElement) -> CGRect? {
        guard let origin = copyPosition(el),
              let size = copySize(el),
              size.width > 1, size.height > 1
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    static func debugSummary(_ el: AXUIElement?) -> String {
        guard let el else { return "nil" }
        let role = copyString(el, kAXRoleAttribute as String) ?? "nil"
        let subrole = copyString(el, kAXSubroleAttribute as String) ?? "nil"
        let frame = bounds(of: el).map(formatRect) ?? "nil"
        let clickCandidate = isClickInputCandidate(role: role, subrole: subrole)
        let clickLabel = clickCandidate.map { $0 ? "input" : "non-input" } ?? "unknown"
        let hasSelection = copyRange(el, kAXSelectedTextRangeAttribute as String) != nil
        let hasValue = copyStringLike(el, kAXValueAttribute as String) != nil || copyInt(el, kAXNumberOfCharactersAttribute as String) != nil
        return "role=\(role) subrole=\(subrole) frame=\(frame) click=\(clickLabel) selection=\(hasSelection) value=\(hasValue)"
    }

    private static func hitScore(of el: AXUIElement) -> Int {
        let role = copyString(el, kAXRoleAttribute as String) ?? ""
        let subrole = copyString(el, kAXSubroleAttribute as String)
        if let explicit = isClickInputCandidate(role: role, subrole: subrole) {
            return explicit ? 3 : -3
        }
        let lowerRole = role.lowercased()
        if lowerRole.contains("text") || lowerRole.contains("editor") || lowerRole.contains("field") {
            return 2
        }
        if copyRange(el, kAXSelectedTextRangeAttribute as String) != nil
            || copyInt(el, kAXNumberOfCharactersAttribute as String) != nil
            || copyString(el, kAXValueAttribute as String) != nil {
            return 1
        }
        return 0
    }

    private static func area(of rect: CGRect) -> CGFloat {
        rect.width * rect.height
    }

    private static func distance(of rect: CGRect, to point: CGPoint) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return sqrt(dx * dx + dy * dy)
    }

    private static func isClickInputCandidate(role: String, subrole: String? = nil) -> Bool? {
        let lowerRole = role.lowercased()
        let lowerSubrole = subrole?.lowercased() ?? ""

        if role == kAXTextFieldRole || role == kAXTextAreaRole {
            return true
        }
        if lowerRole.contains("textfield")
            || lowerRole.contains("textarea")
            || lowerRole.contains("searchfield")
            || lowerRole.contains("combo")
            || lowerRole.contains("editor")
            || lowerSubrole.contains("textfield")
        {
            return true
        }
        if lowerRole.contains("button")
            || lowerRole.contains("menu")
            || lowerRole.contains("toolbar")
            || lowerRole.contains("checkbox")
            || lowerRole.contains("radio")
            || lowerRole.contains("link")
            || lowerRole.contains("tab")
            || lowerRole.contains("popup")
            || lowerRole.contains("slider")
            || lowerRole.contains("stepper")
            || lowerRole.contains("splitter")
            || lowerRole.contains("scrollbar")
        {
            return false
        }
        return nil
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

    static func copyPosition(_ el: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    static func copySize(_ el: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    /// 指定字符范围在屏幕上的矩形（参数化属性 AXBoundsForRange）。
    static func copyBoundsForRange(_ el: AXUIElement, _ range: CFRange) -> CGRect? {
        var r = range
        guard let rangeValue = AXValueCreate(.cfRange, &r) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            el, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &value
        ) == .success,
            let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }
}
