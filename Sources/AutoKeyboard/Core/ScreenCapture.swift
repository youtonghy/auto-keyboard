import CoreGraphics

/// 屏幕像素捕获（需「屏幕录制」权限）。
enum ScreenCapture {
    /// 截取屏幕指定矩形（CG 全局坐标、点单位；跨所有可见窗口合成）。
    static func image(rect: CGRect) -> CGImage? {
        guard rect.width > 0, rect.height > 0, !CGRectIsNull(rect) else { return nil }
        return CGWindowListCreateImage(
            rect,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.nominalResolution]
        )
    }
}
