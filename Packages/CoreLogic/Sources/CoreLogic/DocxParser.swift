import Foundation
import ZIPFoundation

/// 从 .docx（本质是 ZIP 包）中提取纯文本。
/// 读取内部 word/document.xml，用 XMLParser 收集 <w:t> 文本节点，
/// 以 </w:p> 换行，<w:tab> 转制表符。
public struct DocxParser {

    public init() {}

    /// 提取 docx 文本；失败返回 nil。
    public func extractText(from url: URL) -> String? {
        guard let archive = Archive(url: url, accessMode: .read) else { return nil }

        var target: Entry?
        for entry in archive where entry.path.hasSuffix("document.xml") {
            target = entry
            break
        }
        guard let entry = target else { return nil }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("xml")
        do {
            try archive.extract(entry, to: tmp)
            let data = try Data(contentsOf: tmp)
            return parseDocumentXML(data)
        } catch {
            return nil
        }
    }

    private func parseDocumentXML(_ data: Data) -> String {
        let parser = DocxXMLParser()
        parser.parse(data: data)
        return parser.result
    }
}

private final class DocxXMLParser: NSObject, XMLParserDelegate {
    private var textBuffer = ""
    private var inText = false
    private(set) var result = ""

    func parse(data: Data) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        result = textBuffer
    }

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        if elementName == "w:t" { inText = true }
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        switch elementName {
        case "w:t": inText = false
        case "w:p": textBuffer.append("\n")
        case "w:tab": textBuffer.append("\t")
        case "w:br", "w:cr": textBuffer.append("\n")
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { textBuffer.append(string) }
    }
}
