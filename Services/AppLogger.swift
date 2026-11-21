import Foundation

/// 轻量线程安全文件日志，记录朗读/生命周期关键事件，便于用户导出后定位「后台自动退出」。
/// 日志写到 Documents/朗读日志.txt，超过 1MB 自动轮转保留上一份。
final class AppLogger {
    static let shared = AppLogger()

    private let lock = NSLock()
    private let fm = FileManager.default
    private let url: URL = {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return d.appendingPathComponent("朗读日志.txt")
    }()
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()

    private init() {}

    static func log(_ msg: String, _ file: String = #fileID, _ line: Int = #line) {
        shared.write(msg, file, line)
    }

    private func write(_ msg: String, _ file: String, _ line: Int) {
        lock.lock()
        defer { lock.unlock() }
        let ts = dateFormatter.string(from: Date())
        let lineText = "[\(ts)] \(msg)  (\(file):\(line))\n"
        guard let data = lineText.data(using: .utf8) else { return }
        if fm.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url, options: .atomic)
        }
        rotateIfNeeded()
    }

    private func rotateIfNeeded() {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 1_048_576 else { return }
        let backup = url.deletingLastPathComponent().appendingPathComponent("朗读日志.1.txt")
        try? fm.removeItem(at: backup)
        try? fm.moveItem(at: url, to: backup)
    }

    /// 供设置页读取/导出
    var logText: String {
        lock.lock(); defer { lock.unlock() }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? "（暂无日志）"
    }

    var logURL: URL { url }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        try? fm.removeItem(at: url)
    }

    /// 记录一次「启动」分隔线
    func markLaunch() {
        AppLogger.log("========== App 启动 ==========")
    }
}
