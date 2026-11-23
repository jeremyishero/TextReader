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
            // 必须立即刷盘：App 被 iOS 强杀(SIGKILL)时进程内缓冲全丢，
            // 不 synchronize 就看不到「退出前最后一行」，日志失去诊断价值。
            try? handle.synchronize()
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

    /// 设置页预览：从**文件末尾**读末尾若干行——重启后仍能看到上次退出前的记录。
    /// 只读最后 64KB（不是整份文件），避免大日志卡 UI；主文件超 1MB 会轮转到 .1.txt，
    /// 故两份文件都读末尾后合并取最后 N 行。
    func tailText(lines: Int) -> String {
        lock.lock(); defer { lock.unlock() }
        try? handle?.synchronize()   // 把内存句柄缓冲刷盘，确保读到最新日志
        var all: [String] = []
        let files = [url, url.deletingLastPathComponent().appendingPathComponent("朗读日志.1.txt")]
        for f in files {
            guard fm.fileExists(atPath: f.path),
                  let readHandle = try? FileHandle(forReadingFrom: f) else { continue }
            let size = (try? readHandle.seekToEnd()) ?? 0
            let readLen = Int(min(size, 64 * 1024))
            if readLen > 0 {
                readHandle.seek(toFileOffset: size - UInt64(readLen))
                if let data = try? readHandle.read(upToCount: readLen),
                   let text = String(data: data, encoding: .utf8) {
                    all.append(contentsOf: text.split(separator: "\n").map(String.init))
                }
            }
            try? readHandle.close()
        }
        let tail = all.suffix(max(0, lines))
        return tail.isEmpty ? "（暂无日志）" : tail.joined(separator: "\n")
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
