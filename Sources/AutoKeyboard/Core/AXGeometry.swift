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
    private static let minCaptureWidth: CGFloat = 320
    private static let maxCaptureWidth: CGFloat = 1200

    /// 光标定位结果：屏幕矩形 + 来源（用于调试日志）。
    struct CaretLocation {
        let rect: CGRect
        let source: String
    }

    /// 光标在屏幕上的矩形：优先选中范围 / 光标单字符的 bounds，退回焦点元素 bounds，
    /// 再退回窗口 bounds（无法精确到光标，但可整窗 OCR）。都取不到才返回 nil。
    static func caretScreenRect(element: AXUIElement?, window: AXUIElement?) -> CaretLocation? {
        if let element {
            if let selection = AX.copyRange(element, kAXSelectedTextRangeAttribute as String) {
                // 有选区：直接用选区范围的 bounds
                if selection.length > 0,
                   let rect = AX.copyBoundsForRange(element, selection),
                   rect.width > 1, rect.height > 1 {
                    return CaretLocation(rect: rect, source: "selection")
                }
                // 纯光标：探取光标处单字符的 bounds（高度≈行高）
                let probe = CFRange(location: selection.location, length: 1)
                if let rect = AX.copyBoundsForRange(element, probe), rect.height > 1 {
                    return CaretLocation(rect: rect, source: "caret")
                }
            }
            // 退回：焦点元素整体 bounds
            if let origin = AX.copyPosition(element),
               let size = AX.copySize(element),
               size.width > 1, size.height > 1 {
                return CaretLocation(rect: CGRect(origin: origin, size: size), source: "element")
            }
        }
        // 最后兜底：窗口 bounds（无法定位光标，仅用于整窗 OCR）。
        if let window,
           let origin = AX.copyPosition(window),
           let size = AX.copySize(window),
           size.width > 1, size.height > 1 {
            return CaretLocation(rect: CGRect(origin: origin, size: size), source: "window")
        }
        return nil
    }

    /// 以光标为中心构造捕获矩形：竖直方向覆盖若干行（含「光标行 + 上方若干行」），
    /// 水平方向取光标宽度的若干倍并限幅，最后裁剪到显示器范围内。
    static func captureRect(around caretRect: CGRect) -> CGRect {
        let lineHeight = max(caretRect.height, 16)
        let halfHeight = lineHeight * bandHalfLines
        var width = caretRect.width * 4
        width = min(max(width, minCaptureWidth), maxCaptureWidth)

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
}
