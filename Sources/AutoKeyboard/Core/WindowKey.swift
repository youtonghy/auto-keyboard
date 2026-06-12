import ApplicationServices

// 私有但被广泛使用的符号，用于从 AXUIElement 取 CGWindowID
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: inout CGWindowID) -> AXError

struct WindowKey: Hashable {
    let raw: String

    init(bundleID: String, window: AXUIElement?, title: String) {
        if let window {
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(window, &wid) == .success, wid != 0 {
                raw = "\(bundleID)#w\(wid)"
                return
            }
        }
        raw = "\(bundleID)#t\(title.hashValue)"
    }
}
