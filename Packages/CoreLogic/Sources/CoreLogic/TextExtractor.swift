import Foundation

/// 统一文本提取入口：txt / docx。
/// 注意：PDF 文本提取依赖 PDFKit（Apple 平台专用框架），不放入本纯逻辑包，
/// 由 App 层在导入 .pdf 时直接用 PDFKit 处理。
public struct TextExtractor {

    public init() {}

    /// 提取文本；无法识别或失败时回退按 txt 处理。
    public func extract(from url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "docx":
            return DocxParser().extractText(from: url)
        default:
            return extractPlainText(url)
        }
    }

    /// txt / 未知类型：依次尝试 UTF-8 → NSString 编码探测（兼容 GBK 等）→ UTF-16
    /// → 显式 GB18030（GBK/GB2312 超集）→ Big5 → Windows-1252。
    /// 国内旧编码中文 txt（GBK/GB2312）系统自动探测常识别失败，需显式解码。
    public func extractPlainText(_ url: URL) -> String? {
        if let s = try? String(contentsOf: url, encoding: .utf8), !s.isEmpty { return s }
        let path = url.path
        var enc: UInt = 0
        if let s = try? NSString(contentsOfFile: path, usedEncoding: &enc) as String, !s.isEmpty {
            return s
        }
        if let s = try? String(contentsOf: url, encoding: .utf16), !s.isEmpty { return s }
        for e in Self.chineseLegacyEncodings {
            if let s = try? String(contentsOf: url, encoding: e), !s.isEmpty { return s }
        }
        return nil
    }

    /// 显式的中文旧编码列表（GB18030 为 GBK/GB2312 的超集）。
    private static let chineseLegacyEncodings: [String.Encoding] = {
        var encs: [String.Encoding] = []
        let raw = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if raw != UInt(kCFStringEncodingInvalidId) { encs.append(String.Encoding(rawValue: raw)) }
        let big5 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))
        if big5 != UInt(kCFStringEncodingInvalidId) { encs.append(String.Encoding(rawValue: big5)) }
        encs.append(.windowsCP1252)
        return encs
    }()
}
