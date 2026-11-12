import Foundation

/// 朗读进度：断点续读依据。
struct ReadingProgress: Codable {
    var segmentIndex: Int        // 朗读分段索引（角色分声模式下为段索引，普通模式为分块索引）
    var analyzed: Bool           // 保存时的朗读模式（是否角色分声）
    var paragraphIndex: Int?     // 阅读段落索引（纯阅读/目录跳转时所在段落；旧档无此字段 → nil）
    var updatedAt: Date

    init(segmentIndex: Int, analyzed: Bool, paragraphIndex: Int? = nil, updatedAt: Date = Date()) {
        self.segmentIndex = segmentIndex
        self.analyzed = analyzed
        self.paragraphIndex = paragraphIndex
        self.updatedAt = updatedAt
    }

    // 旧索引文件里没有 paragraphIndex 字段：显式 decodeIfPresent，保证升级后旧档仍能解码、进度不丢。
    private enum CodingKeys: String, CodingKey {
        case segmentIndex, analyzed, paragraphIndex, updatedAt
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        segmentIndex = try c.decode(Int.self, forKey: .segmentIndex)
        analyzed = try c.decode(Bool.self, forKey: .analyzed)
        paragraphIndex = try c.decodeIfPresent(Int.self, forKey: .paragraphIndex)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(segmentIndex, forKey: .segmentIndex)
        try c.encode(analyzed, forKey: .analyzed)
        try c.encodeIfPresent(paragraphIndex, forKey: .paragraphIndex)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
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
