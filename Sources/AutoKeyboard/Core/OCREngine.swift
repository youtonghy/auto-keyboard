import CoreGraphics
import Foundation
import Vision

/// 基于 Apple Vision 的屏幕 OCR：截取光标附近区域、识别文本，
/// 选出图像竖直中心（即光标位置）附近的若干行，拼接送入中英分类。
///
/// 捕获区由调用方以光标为中心构造，因此光标≈图像竖直中心（归一化 y≈0.5），
/// 选行无需关心 AX/CG 的坐标原点方向。OCR 在后台队列执行，不阻塞主线程。
struct OCREngine {
    /// 「光标附近」筛选带宽：行中心落在 0.5 ± 此比例内（boundingBox 归一化、左下原点）。
    private static let bandRatio: CGFloat = 0.35
    private static let maxLines = 6

    /// 识别光标附近文本。`captureRect` 应以 `caretScreenRect` 为中心构造。
    func recognize(caretScreenRect: CGRect, captureRect: CGRect) async -> String? {
        guard captureRect.width > 1, captureRect.height > 1,
              let cgImage = ScreenCapture.image(rect: captureRect) else { return nil }
        return await recognizeCenterLines(in: cgImage)
    }

    private func recognizeCenterLines(in image: CGImage) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["zh-Hans", "en-US"]
                request.usesLanguageCorrection = true
                let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let lines: [(text: String, midY: CGFloat)] = (request.results ?? []).compactMap { obs in
                    guard let candidate = obs.topCandidates(1).first else { return nil }
                    return (candidate.string, obs.boundingBox.midY)
                }
                let ordered = lines.sorted { $0.midY > $1.midY } // 屏幕从上到下
                let nearCaret = ordered.filter { abs($0.midY - 0.5) <= Self.bandRatio }
                let picked = nearCaret.isEmpty
                    ? Array(ordered.prefix(Self.maxLines))
                    : Array(nearCaret.prefix(Self.maxLines))
                continuation.resume(returning: picked.map(\.text).joined(separator: "\n"))
            }
        }
    }
}
