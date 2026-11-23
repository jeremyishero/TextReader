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
    /// 内存环形缓冲（最多 400 行）：设置页预览只读这里，不再同步读整份大文件。
    private var ring: [String] = []
    private let ringLimit = 400
    /// 复用 FileHandle，避免每条日志一次 open/seek/close 的同步磁盘 IO（卡顿放大器）。
    private var handle: FileHandle?
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
        // 内存环形缓冲：供设置页秒级预览，无需读磁盘
        ring.append(lineText)
        if ring.count > ringLimit { ring.removeFirst(ring.count - ringLimit) }
        guard let data = lineText.data(using: .utf8) else { return }
        // 复用句柄；第一次打开或轮转后重建
        if handle == nil {
            if !fm.fileExists(atPath: url.path) { try? Data().write(to: url) }
            handle = try? FileHandle(forWritingTo: url)
        }
        if let handle {
            handle.seekToEndOfFile()
            handle.write(data)
        }
        rotateIfNeeded()
    }

    private func rotateIfNeeded() {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 1_048_576 else { return }
        try? handle?.synchronize()
        handle?.closeFile()
        handle = nil
        let backup = url.deletingLastPathComponent().appendingPathComponent("朗读日志.1.txt")
        try? fm.removeItem(at: backup)
        try? fm.moveItem(at: url, to: backup)
    }

    /// 供设置页读取/导出（整文件，仅导出时用）
    var logText: String {
        lock.lock(); defer { lock.unlock() }
        try? handle?.synchronize()
        return (try? String(contentsOf: url, encoding: .utf8)) ?? "（暂无日志）"
    }

    /// 设置页预览：从内存环形缓冲取末尾若干行，零磁盘 IO，不会卡 UI。
    func tailText(lines: Int) -> String {
        lock.lock(); defer { lock.unlock() }
        let tail = ring.suffix(max(0, lines))
        return tail.isEmpty ? "（暂无日志）" : tail.joined()
    }

    var logURL: URL { url }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        handle?.closeFile()
        handle = nil
        ring.removeAll()
        try? fm.removeItem(at: url)
    }

    /// 记录一次「启动」分隔线
    func markLaunch() {
        AppLogger.log("========== App 启动 ==========")
    }
}
