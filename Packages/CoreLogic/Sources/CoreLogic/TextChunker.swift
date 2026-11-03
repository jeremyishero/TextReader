import Foundation

/// 将长文本切分为适合逐句朗读的片段（用于「未解析」模式的直接朗读）。
public struct TextChunker {

    public init() {}

    /// 按中英文标点与换行切句，并按 maxLength 合并，避免单句过短或过长。
    public func chunk(_ text: String, maxLength: Int = 200) -> [String] {
        let separators = CharacterSet(charactersIn: "。！？!?；;：:\n.…—")
        let raw = text.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var out: [String] = []
        var buffer = ""
        for sentence in raw {
            if !buffer.isEmpty, buffer.count + sentence.count > maxLength {
                out.append(buffer)
                buffer = ""
            }
            buffer += sentence + "。"
        }
        if !buffer.isEmpty { out.append(buffer) }
        return out
    }
}
