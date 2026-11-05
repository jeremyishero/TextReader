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
    /// 文件复制成功但提取不到任何文本（损坏、加密、空文件）。
    case noTextExtracted

    var errorDescription: String? {
        switch self {
        case .copyFailed(let e):
            return "无法读取所选文件：\(e.localizedDescription)。请确认文件仍存在、未被移动，若来自 iCloud 请先确认已下载到本机后重试。"
        case .noTextExtracted:
            return "导入失败：未能从该文件中提取到文本内容。文件可能已损坏、被加密，或内容为空。"
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
        try? fm.removeItem(at: dest)
        throw ImportError.noTextExtracted
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

    // MARK: 删除

    func delete(_ offsets: IndexSet) {
        for i in offsets {
            let item = documents[i]
            let file = importsDir.appendingPathComponent(item.storedFileName)
            try? fm.removeItem(at: file)
        }
        documents.remove(atOffsets: offsets)
        saveIndex()
    }

    // MARK: PDF（PDFKit / Vision 仅 Apple 平台可用，故放在 App 层）

    /// 逐页提取文本；无文本层的页（扫描版）自动 OCR。nonisolated static：供后台线程调用，不触碰实例状态。
    private nonisolated static func extractPDFText(_ url: URL, ocrUsed: inout Bool) -> String? {
        guard let doc = PDFDocument(url: url) else { return nil }
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
