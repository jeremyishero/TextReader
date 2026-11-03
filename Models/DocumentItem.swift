import Foundation

/// 朗读进度：断点续读依据。
struct ReadingProgress: Codable {
    var segmentIndex: Int        // 段/分块索引（角色分声模式下为段索引，普通模式为分块索引）
    var analyzed: Bool           // 保存时的朗读模式（是否角色分声）
    var updatedAt: Date
}

/// 已导入的文档（含提取出的文本缓存）。
struct DocumentItem: Identifiable, Codable {
    let id: UUID
    var name: String
    var fileType: String          // "txt" / "docx" / "pdf"
    var storedFileName: String    // 沙盒内文件名（Imports 目录下）
    var importedAt: Date
    var extractedText: String?    // 提取缓存，避免重复解析
    var ocrUsed: Bool?            // 是否经过 OCR（扫描版 PDF），旧索引无此字段视为 false
    var progress: ReadingProgress? // 朗读进度记忆
}
