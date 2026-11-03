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

    /// txt / 未知类型：优先 UTF-8，失败回退 NSString 编码探测（兼容 GBK 等），再试 UTF-16。
    public func extractPlainText(_ url: URL) -> String? {
        if let s = try? String(contentsOf: url, encoding: .utf8), !s.isEmpty { return s }
        let path = url.path
        var enc: UInt = 0
        if let s = try? NSString(contentsOfFile: path, usedEncoding: &enc) as String, !s.isEmpty {
            return s
        }
        return try? String(contentsOf: url, encoding: .utf16)
    }
}
