import ApplicationServices
import CoreGraphics

/// 把 AX 元素几何转换为屏幕坐标矩形，用于 OCR 截屏定位「光标附近」区域。
///
/// 坐标假设：AX 的 position / boundsForRange 返回 CG 全局坐标（主显示器左上为原点、
/// y 向下），与 `CGWindowListCreateImage` 一致。这是现代 macOS 的标准行为；
/// 若实测发现竖直方向取反，应在此处统一做翻转。
@MainActor
enum AXGeometry {
    /// 捕获区以光标为竖直中心、上下各扩展的行数。
    private static let bandHalfLines: CGFloat = 2.5
    private static let minCaptureWidth: CGFloat = 600
    private static let maxCaptureWidth: CGFloat = 1200

    /// 光标定位结果：屏幕矩形 + 来源（用于调试日志）。
    struct CaretLocation {
        let rect: CGRect
        let source: String
    }

    /// 光标在屏幕上的矩形，按优先级：
    /// 选区/光标单字符 bounds → hit-test 元素 → 尺寸合理的焦点元素 → 触发点 → 当前鼠标 → 大元素/窗口。
    /// 关键是使用触发事件时保存下来的 `focusPoint`，避免防抖/OCR await 期间鼠标移动后读错区域。
    static func caretScreenRect(
        element: AXUIElement?,
        hitElement: AXUIElement? = nil,
        focusPoint: CGPoint? = nil,
        window: AXUIElement?
    ) -> CaretLocation? {
        if let rect = preciseTextRect(from: element) {
            return CaretLocation(rect: rect, source: "selection")
        }
        if let rect = preciseTextRect(from: hitElement) {
            return CaretLocation(rect: rect, source: "hit-caret")
        }
        if let bounds = compactBounds(of: hitElement, maxHeight: 260, maxWidth: 1200) {
            return CaretLocation(rect: pointAdjusted(bounds, toward: focusPoint), source: "hit-element")
        }
        if let bounds = compactBounds(of: element, maxHeight: 220, maxWidth: 1000) {
            return CaretLocation(rect: pointAdjusted(bounds, toward: focusPoint), source: "element")
        }
        if let focusPoint {
            return CaretLocation(rect: CGRect(origin: focusPoint, size: CGSize(width: 1, height: 1)), source: "focus-point")
        }
        if let mouse = CGEvent(source: nil)?.location {
            return CaretLocation(rect: CGRect(origin: mouse, size: CGSize(width: 1, height: 1)), source: "mouse-live")
        }
        if let bounds = bounds(of: element) {
            return CaretLocation(rect: pointAdjusted(bounds, toward: focusPoint), source: "element-large")
        }
        if let bounds = bounds(of: window) {
            return CaretLocation(rect: pointAdjusted(bounds, toward: focusPoint), source: "window")
        }
        return nil
    }

    /// 以光标为中心构造捕获矩形：竖直方向覆盖若干行（含「光标行 + 上方若干行」），
    /// 水平方向取光标宽度的若干倍并限幅，最后裁剪到显示器范围内。
    static func captureRect(around caretRect: CGRect) -> CGRect {
        // lineHeight 上限避免兜底到窗口/大元素时把捕获带高撑成全屏。
        let lineHeight = min(max(caretRect.height, 16), 36)
        let halfHeight = lineHeight * bandHalfLines
        let width = min(max(caretRect.width, minCaptureWidth), maxCaptureWidth)

        var rect = CGRect(
            x: caretRect.midX - width / 2,
            y: caretRect.midY - halfHeight,
            width: width,
            height: halfHeight * 2
        )
        let bounds = globalDesktopBounds()
        if !CGRectIsNull(bounds) {
            rect = CGRectIntersection(rect, bounds)
        }
        return rect
    }

    /// 所有活动显示器范围的并集（CG 全局坐标）。
    private static func globalDesktopBounds() -> CGRect {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        guard count > 0 else { return CGRect.null }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).reduce(CGRect.null) { CGRectUnion($0, CGDisplayBounds($1)) }
    }

    private static func preciseTextRect(from element: AXUIElement?) -> CGRect? {
        guard let element,
              let selection = AX.copyRange(element, kAXSelectedTextRangeAttribute as String)
        else { return nil }
        if selection.length > 0,
           let rect = AX.copyBoundsForRange(element, selection),
           rect.width > 1, rect.height > 1 {
            return rect
        }
        let probe = CFRange(location: selection.location, length: 1)
        guard let rect = AX.copyBoundsForRange(element, probe), rect.height > 1 else { return nil }
        return rect
    }

    private static func compactBounds(of element: AXUIElement?, maxHeight: CGFloat, maxWidth: CGFloat) -> CGRect? {
        guard let rect = bounds(of: element),
              rect.height > 1, rect.width > 1,
              rect.height <= maxHeight, rect.width <= maxWidth
        else { return nil }
        return rect
    }

    private static func bounds(of element: AXUIElement?) -> CGRect? {
        guard let element,
              let origin = AX.copyPosition(element),
              let size = AX.copySize(element),
              size.width > 1, size.height > 1
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func pointAdjusted(_ rect: CGRect, toward point: CGPoint?) -> CGRect {
        guard let point, rect.contains(point), rect.height > 80 else { return rect }
        return CGRect(x: point.x, y: point.y, width: 1, height: 1)
    }
}
