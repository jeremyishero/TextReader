import SwiftUI
import AVFoundation

@main
struct TextReaderApp: App {
    @StateObject private var store = DocumentStore()
    @StateObject private var player = TTSPlayer()
    @StateObject private var settings = AppSettings()

    init() {
        CrashReporter.install()
    }

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 0) {
                DocumentListView()
                    .task { configureAudioSession() }
                PlayerBar()
            }
            .environmentObject(store)
            .environmentObject(player)
            .environmentObject(settings)
        }
    }

    /// 配置后台音频会话，使锁屏/后台仍可朗读。
    func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("AudioSession 配置失败: \(error)")
        }
    }
}

/// 崩溃采集器：捕获未捕获异常与常见致命信号（Swift 致命错误走 SIGTRAP/SIGABRT），
/// 把调用栈写入 Documents/crash_report.txt，供「设置」页面展示，便于在无 Xcode 的真机上定位崩溃。
/// 注：信号处理器内仅使用异步信号安全调用（open/write/close/strlen/memcpy），避免死锁。
enum CrashReporter {
    private static let fileName = "crash_report.txt"
    /// 安装时把崩溃日志路径以 C 字符串形式固化到缓冲区，供信号处理器安全使用。
    private static var pathBuf: UnsafeMutablePointer<CChar>?

    static func install() {
        // 预计算并固化路径 C 字符串
        let dir = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first
            ?? NSTemporaryDirectory()
        let path = (dir as NSString).appendingPathComponent(fileName)
        if let c = (path as NSString).utf8String {
            let len = strlen(c)
            let buf = UnsafeMutablePointer<CChar>.allocate(capacity: Int(len) + 1)
            memcpy(buf, c, Int(len) + 1)
            pathBuf = buf
        }

        NSSetUncaughtExceptionHandler { exception in
            let symbols = (exception.callStackSymbols as? [String])?.joined(separator: "\n") ?? "<no symbols>"
            let msg = """
            ========== UNCAUGHT EXCEPTION ==========
            \(Date())
            Name: \(exception.name.rawValue)
            Reason: \(exception.reason ?? "<none>")
            Stack:
            \(symbols)
            
            """
            CrashReporter.appendText(msg)
        }

        let pairs: [(Int32, String)] = [
            (SIGTRAP, "SIGTRAP"),
            (SIGABRT, "SIGABRT"),
            (SIGSEGV, "SIGSEGV"),
            (SIGBUS, "SIGBUS"),
            (SIGILL, "SIGILL"),
            (SIGFPE, "SIGFPE"),
        ]
        for (sig, name) in pairs {
            signal(sig) { signum in
                CrashReporter.writeSignal(signum, name)
                signal(signum, SIG_DFL)
                raise(signum)
            }
        }
    }

    /// 信号处理器：仅用异步信号安全调用写栈，绝不调用 Foundation。
    private static func writeSignal(_ signum: Int32, _ name: String) {
        var addrs = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
        let n = backtrace(&addrs, Int32(addrs.count))
        let syms = backtrace_symbols(&addrs, n)
        var header = "\n========== SIGNAL \(name) (\(signum)) ==========\n\(Date())\n"
        header += "Backtrace:\n"
        _ = header.utf8CString.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                writeRaw(base.bindMemory(to: CChar.self), count: header.utf8CString.count - 1)
            }
        }
        if let syms {
            for i in 0..<Int(n) {
                if let s = syms[i] {
                    let len = strlen(s)
                    writeRaw(s, count: Int(len))
                    let nl: CChar = 10
                    withUnsafePointer(to: nl) { writeRaw($0, count: 1) }
                }
            }
            free(syms)
        }
    }

    /// 用 open/write/close 异步信号安全地把 C 字符串追加进日志文件。
    private static func writeRaw(_ ptr: UnsafePointer<CChar>, count: Int) {
        guard let pathBuf else { return }
        let fd = open(pathBuf, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        if fd >= 0 {
            _ = write(fd, ptr, count)
            close(fd)
        }
    }

    /// 在异常处理器（安全上下文）中使用 Foundation 追加文本。
    private static func appendText(_ text: String) {
        guard let pathBuf else { return }
        let url = URL(fileURLWithPath: String(cString: pathBuf))
        let prev = (try? String(contentsOf: url)) ?? ""
        let combined = prev.isEmpty ? text : prev + "\n" + text
        try? combined.write(to: url, options: .atomic)
    }

    /// 读取最近一次崩溃日志（无则返回 nil）。
    static func lastReport() -> String? {
        guard let pathBuf else { return nil }
        let url = URL(fileURLWithPath: String(cString: pathBuf))
        guard let s = try? String(contentsOf: url), !s.isEmpty else { return nil }
        return s
    }

    /// 清除已读取的崩溃日志。
    static func clear() {
        guard let pathBuf else { return }
        let url = URL(fileURLWithPath: String(cString: pathBuf))
        try? FileManager.default.removeItem(at: url)
    }
}
