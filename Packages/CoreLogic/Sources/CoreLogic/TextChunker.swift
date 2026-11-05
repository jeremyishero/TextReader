import Foundation

/// 将长文本切分为适合逐句朗读的片段（用于「未解析」模式的直接朗读）。
public struct TextChunker {

    public init() {}

    /// 段落末尾标记：块尾的 "\n" 由朗读器识别为段落间停顿（postUtteranceDelay）。
    public static let paragraphBreakMarker = "\n"

    /// 按自然段组织：段落内按标点切句并按 maxLength 合并；**绝不跨段合并**，
    /// 段落最后一个块追加 "\n" 标记，朗读时换段有明显停顿，不会「直接接上」。
    public func chunk(_ text: String, maxLength: Int = 200) -> [String] {
        let sentenceSeparators = CharacterSet(charactersIn: "。！？!?；;：:.…—")
        let paragraphs = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var out: [String] = []
        for (pi, para) in paragraphs.enumerated() {
            let isLastParagraph = (pi == paragraphs.count - 1)
            let sentences = para.components(separatedBy: sentenceSeparators)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            var buffer = ""
            for sentence in sentences {
                if !buffer.isEmpty, buffer.count + sentence.count > maxLength {
                    out.append(buffer)
                    buffer = ""
                }
                buffer += sentence + "。"
            }
            if !buffer.isEmpty {
                out.append(isLastParagraph ? buffer : buffer + Self.paragraphBreakMarker)
            }
        }
        return out
    }
}
