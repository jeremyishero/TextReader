import Foundation
import PDFKit
import Vision

/// 扫描版 PDF 的 OCR 识别回退：把无文本层的 PDF 页渲染为位图后用 Vision 识别文字。
enum OCRTextRecognizer {

    /// 识别一页；无可识别文本返回 nil。
    static func recognize(page: PDFPage) -> String? {
        let bounds = page.bounds(for: .mediaBox)
        // 约 300 DPI 渲染，兼顾精度与内存
        let scale: CGFloat = 300.0 / 72.0
        let target = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let image = page.thumbnail(of: target, for: .mediaBox)
        guard let cgImage = image.cgImage else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do { try handler.perform([request]) } catch { return nil }

        let lines = (request.results as? [VNRecognizedTextObservation])?
            .compactMap { $0.topCandidates(1).first?.string } ?? []
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
