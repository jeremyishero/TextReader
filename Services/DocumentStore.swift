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

    /// 从系统文件选择器拿到的 url 导入（复制进沙盒并提取文本；扫描版 PDF 自动 OCR）。
    func importFile(from url: URL) async throws {
        let ext = url.pathExtension.lowercased()
        let id = UUID()
        let dest = importsDir.appendingPathComponent("\(id.uuidString).\(ext)")
        try fm.copyItem(at: url, to: dest)

        var ocr = false
        let text: String?
        if ext == "pdf" {
            text = extractPDFText(dest, ocrUsed: &ocr)
        } else {
            text = TextExtractor().extract(from: dest)
        }

        let item = DocumentItem(
            id: id,
            name: url.deletingPathExtension().lastPathComponent,
            fileType: ext,
            storedFileName: dest.lastPathComponent,
            importedAt: Date(),
            extractedText: text,
            ocrUsed: ocr,
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

    /// 逐页提取文本；无文本层的页（扫描版）自动 OCR。
    private func extractPDFText(_ url: URL, ocrUsed: inout Bool) -> String? {
        guard let doc = PDFDocument(url: url) else { return nil }
        var out = ""
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let s = page.string ?? ""
            if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // 无文本层 → OCR
                if let ocrText = OCRTextRecognizer.recognize(page: page) {
                    out += ocrText + "\n"
                    ocr = true
                }
            } else {
                out += s + "\n"
            }
        }
        return out.isEmpty ? nil : out
    }
}
