import Foundation

/// 文件调试日志：写入 `~/Library/Logs/<bundleID>/debug.log`，供排障分析。
/// 仅在设置中开启「调试日志」时由调用方写入；写操作派发到后台队列，best-effort、不阻塞主线程。
@MainActor
final class FileLogger {
    let logURL: URL
    private let writeQueue = DispatchQueue(label: "com.autokeyboard.filelogger")
    private let formatter = ISO8601DateFormatter()

    init() {
        let logsRoot = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        let dir = logsRoot.appendingPathComponent(
            Bundle.main.bundleIdentifier ?? "AutoKeyboard", isDirectory: true
        )
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        logURL = dir.appendingPathComponent("debug.log")
    }

    func log(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        let url = logURL
        writeQueue.async {
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: url.path) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: url)
            }
        }
    }

    func clear() {
        let url = logURL
        writeQueue.async {
            try? Data().write(to: url)
        }
    }
}
