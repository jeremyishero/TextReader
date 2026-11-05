import Foundation
import PDFKit
import CoreLogic

/// 导入文档管理：复制进沙盒、提取文本（含扫描版 PDF OCR 回退）、用 JSON 索引持久化、进度记忆。
@MainActor
final class DocumentStore: ObservableObject {
    @Published var documents: [DocumentItem] = []

    private let fm = FileManager.default
    private var importsDir: URL {
        let base = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Imports", isDirectory: true)
    }
    private var indexURL: URL { importsDir.appendingPathComponent("index.json") }

    init() { load() }

    // MARK: 持久化

    private func load() {
        try? fm.createDirectory(at: importsDir, withIntermediateDirectories: true)
        guard let data = try? Data(contentsOf: indexURL),
              let arr = try? JSONDecoder().decode([DocumentItem].self, from: data) else { return }
        documents = arr
    }

    private func saveIndex() {
        guard let data = try? JSONEncoder().encode(documents) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

// MARK: 导入

/// 导入失败原因（供 UI 弹出准确提示）。
enum ImportError: LocalizedError {
    /// 无法读取/复制所选文件（未授权安全作用域、文件被移动或删除、iCloud 未下载等）。
    case copyFailed(underlying: Error)
    /// 文件复制成功但提取不到任何文本（损坏、加密、空文件、不支持的编码）。
    case noTextExtracted(ext: String, bytes: Int64)

    var errorDescription: String? {
        switch self {
        case .copyFailed(let e):
            return "无法读取所选文件：\(e.localizedDescription)。请确认文件仍存在、未被移动，若来自 iCloud 请先确认已下载到本机后重试。"
        case .noTextExtracted(let ext, let bytes):
            let sizeDesc = bytes >= 1024 ? "\(bytes / 1024) KB" : "\(bytes) 字节"
            return "导入失败：未能从 .\(ext) 文件（\(sizeDesc)）中提取到文本内容。文件可能已损坏、被口令加密，或使用了不支持的文本编码。可尝试用电脑上的编辑器将文件另存为 UTF-8 编码后重新导入。"
        }
    }
}

/// 从系统文件选择器拿到的 url 导入（复制进沙盒并提取文本；扫描版 PDF 自动 OCR）。
/// 注意：fileImporter 返回的是安全作用域 URL，必须先 startAccessingSecurityScopedResource 才能读取。
func importFile(from url: URL) async throws {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }

    let ext = url.pathExtension.lowercased()
    let id = UUID()
    let dest = importsDir.appendingPathComponent("\(id.uuidString).\(ext)")
    do {
        try fm.copyItem(at: url, to: dest)
    } catch {
        throw ImportError.copyFailed(underlying: error)
    }

    // 提取文本放到后台线程执行（大文件/扫描版 OCR 可能耗时数秒以上），避免卡住 UI。
    let extracted: (text: String?, ocr: Bool) = await Task.detached(priority: .userInitiated) {
        var ocr = false
        if ext == "pdf" {
            let text = Self.extractPDFText(dest, ocrUsed: &ocr)
            return (text, ocr)
        } else {
            return (TextExtractor().extract(from: dest), false)
        }
    }.value

    guard let text = extracted.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        // 提取不到文本：清理已复制的文件，不给列表留垃圾条目
        let attr = try? fm.attributesOfItem(atPath: dest.path)
        let bytes = (attr?[.size] as? NSNumber)?.int64Value ?? 0
        try? fm.removeItem(at: dest)
        throw ImportError.noTextExtracted(ext: ext, bytes: bytes)
    }

    let item = DocumentItem(
        id: id,
        name: url.deletingPathExtension().lastPathComponent,
        fileType: ext,
        storedFileName: dest.lastPathComponent,
        importedAt: Date(),
        extractedText: text,
        ocrUsed: extracted.ocr,
        progress: nil
    )
    documents.append(item)
    saveIndex()
}

    func text(for item: DocumentItem) -> String? { item.extractedText }

    // MARK: 进度记忆

    /// 保存某文档的朗读进度（断点续读）。
    func updateProgress(documentId: UUID, segmentIndex: Int, analyzed: Bool) {
        guard let i = documents.firstIndex(where: { $0.id == documentId }) else { return }
        documents[i].progress = ReadingProgress(segmentIndex: segmentIndex, analyzed: analyzed, updatedAt: Date())
        saveIndex()
    }

    func progress(for item: DocumentItem) -> ReadingProgress? { item.progress }

    // MARK: 解析结果缓存（按文档持久化，重进/重启不丢失）

    private struct AnalysisCache: Codable {
        let result: AnalysisResult
        let source: String   // "cloud" / "local"
    }

    private func analysisURL(_ documentId: UUID) -> URL {
        importsDir.appendingPathComponent("\(documentId.uuidString).analysis.json")
    }

    /// 保存某文档的整体解析结果与来源（小圆灯颜色依据）。
    func saveAnalysis(_ result: AnalysisResult, source: String, for documentId: UUID) {
        let cache = AnalysisCache(result: result, source: source)
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: analysisURL(documentId), options: .atomic)
        }
    }

    /// 读取某文档已保存的解析结果；无则返回 nil（小圆灯为灰）。
    func loadAnalysis(for documentId: UUID) -> (result: AnalysisResult, source: String)? {
        guard let data = try? Data(contentsOf: analysisURL(documentId)),
              let cache = try? JSONDecoder().decode(AnalysisCache.self, from: data) else { return nil }
        return (cache.result, cache.source)
    }

    // MARK: 每文档声音配置与黑白名单（各文档互不影响；声音配置可跨文档导入）

    private struct VoiceConfig: Codable { var assignments: [String: String] }   // 角色称呼 → 声音 identifier
    private struct DocNameLists: Codable { var blacklist: [String] = []; var whitelist: [String] = [] }

    private func voiceConfigURL(_ documentId: UUID) -> URL {
        importsDir.appendingPathComponent("\(documentId.uuidString).voicecfg.json")
    }
    private func nameListsURL(_ documentId: UUID) -> URL {
        importsDir.appendingPathComponent("\(documentId.uuidString).lists.json")
    }

    /// 保存某文档的声音配置（角色称呼 → 系统声音 identifier）。
    func saveVoiceConfig(_ assignments: [String: String], for documentId: UUID) {
        let cfg = VoiceConfig(assignments: assignments)
        if let data = try? JSONEncoder().encode(cfg) {
            try? data.write(to: voiceConfigURL(documentId), options: .atomic)
        }
    }

    /// 读取某文档的声音配置；无则返回空表。
    func loadVoiceConfig(for documentId: UUID) -> [String: String] {
        guard let data = try? Data(contentsOf: voiceConfigURL(documentId)),
              let cfg = try? JSONDecoder().decode(VoiceConfig.self, from: data) else { return [:] }
        return cfg.assignments
    }

    /// 保存某文档的人名黑白名单。
    func saveNameLists(black: [String], white: [String], for documentId: UUID) {
        let lists = DocNameLists(blacklist: black, whitelist: white)
        if let data = try? JSONEncoder().encode(lists) {
            try? data.write(to: nameListsURL(documentId), options: .atomic)
        }
    }

    /// 读取某文档的人名黑白名单。
    func loadNameLists(for documentId: UUID) -> (black: [String], white: [String]) {
        guard let data = try? Data(contentsOf: nameListsURL(documentId)),
              let lists = try? JSONDecoder().decode(DocNameLists.self, from: data) else { return ([], []) }
        return (lists.blacklist, lists.whitelist)
    }

    /// 有已保存声音配置的其他文档（供「导入其他文档的人物配置」选择）。
    func documentsWithVoiceConfig(excluding documentId: UUID) -> [DocumentItem] {
        documents.filter { $0.id != documentId && fm.fileExists(atPath: voiceConfigURL($0.id).path) }
    }

    // MARK: 删除

    func delete(_ offsets: IndexSet) {
        for i in offsets {
            let item = documents[i]
            let file = importsDir.appendingPathComponent(item.storedFileName)
            try? fm.removeItem(at: file)
            try? fm.removeItem(at: analysisURL(item.id))
            try? fm.removeItem(at: voiceConfigURL(item.id))
            try? fm.removeItem(at: nameListsURL(item.id))
        }
        documents.remove(atOffsets: offsets)
        saveIndex()
    }

    // MARK: PDF（PDFKit / Vision 仅 Apple 平台可用，故放在 App 层）

    /// 逐页提取文本；无文本层的页（扫描版）自动 OCR。nonisolated static：供后台线程调用，不触碰实例状态。
    private nonisolated static func extractPDFText(_ url: URL, ocrUsed: inout Bool) -> String? {
        guard let doc = PDFDocument(url: url) else { return nil }
        // 空口令加密的 PDF（其他阅读器可自动打开）先尝试解锁
        if doc.isLocked && !doc.unlock(withPassword: "") { return nil }
        var out = ""
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let s = page.string ?? ""
            if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // 无文本层 → OCR
                if let ocrText = OCRTextRecognizer.recognize(page: page) {
                    out += ocrText + "\n"
                    ocrUsed = true
                }
            } else {
                out += s + "\n"
            }
        }
        return out.isEmpty ? nil : out
    }
}
