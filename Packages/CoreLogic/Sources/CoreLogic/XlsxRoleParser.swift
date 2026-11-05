import Foundation
import ZIPFoundation

/// 从「人物解析」表格（.xlsx）导入角色定义。
/// 期望列（按表头自动识别，顺序不限）：姓名 / 别名·别名与身份·别名/身份 / 性别 / 性格特点（可缺省）；序号列忽略。
/// 别名支持「、」「，」「,」「/」分隔；别名中的括号备注（如「吴七（伪装）」）会被剥掉备注保留本名。
public struct XlsxImportedRole {
    public var name: String
    public var aliases: [String]
    public var gender: Gender
    public var note: String?
    public init(name: String, aliases: [String], gender: Gender, note: String? = nil) {
        self.name = name
        self.aliases = aliases
        self.gender = gender
        self.note = note
    }
}

public struct XlsxRoleParser {

    public init() {}

    /// 解析 .xlsx；无法识别时返回空数组。
    public func parseRoles(from url: URL) -> [XlsxImportedRole] {
        // 1) 读取 zip 内的 XML
        guard let archive = try? Archive(url: url, accessMode: .read) else { return [] }
        var sharedStrings: [String] = []
        var sheetData: Data?

        for entry in archive {
            let path = entry.path
            if path == "xl/sharedStrings.xml" {
                if let data = extractEntry(entry, from: archive) {
                    sharedStrings = Self.parseSharedStrings(data)
                }
            } else if path.hasPrefix("xl/worksheets/sheet") && path.hasSuffix(".xml"), sheetData == nil {
                sheetData = extractEntry(entry, from: archive)
            }
        }
        guard let data = sheetData else { return [] }

        // 2) 解析工作表为二维表
        let grid = Self.parseSheet(data, sharedStrings: sharedStrings)
        guard !grid.isEmpty else { return [] }

        // 3) 按表头映射列
        let header = grid[0]
        var nameCol = -1, aliasCol = -1, genderCol = -1, noteCol = -1
        for (i, h) in header.enumerated() {
            let key = h.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.contains("姓名") || key.contains("名字") { nameCol = i }
            else if key.contains("别") { aliasCol = i }               // 别名 / 别称 / 别名/身份
            else if key.contains("性别") { genderCol = i }
            else if key.contains("性格") || key.contains("特点") || key.contains("备注") { noteCol = i }
        }
        guard nameCol >= 0 else { return [] }

        // 4) 数据行 → 角色
        var roles: [XlsxImportedRole] = []
        for row in grid.dropFirst() {
            func cell(_ col: Int) -> String {
                guard col >= 0, col < row.count else { return "" }
                return row[col].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let name = cell(nameCol)
            guard !name.isEmpty else { continue }
            let rawGender = cell(genderCol)
            let gender: Gender = rawGender.contains("女") ? .female : (rawGender.contains("男") ? .male : .neutral)
            let note = noteCol >= 0 ? cell(noteCol) : nil
            let aliases = Self.parseAliases(cell(aliasCol))
            roles.append(XlsxImportedRole(name: name, aliases: aliases, gender: gender, note: note.isEmpty ? nil : note))
        }
        return roles
    }

    // MARK: 别名解析

    /// 「太子、吴七（伪装）」→ ["太子", "吴七"]；「魏将军/魏老将军」→ ["魏将军", "魏老将军"]
    static func parseAliases(_ raw: String) -> [String] {
        guard !raw.isEmpty else { return [] }
        var out: [String] = []
        for part in raw.split(whereSeparator: { "、，,/;； ".contains($0) }) {
            // 剥掉括号备注
            var a = part
            if let re = try? NSRegularExpression(pattern: "（[^）]*）|\\([^)]*\\)") {
                a = re.stringByReplacingMatches(in: a, range: NSRange(location: 0, length: (a as NSString).length), withTemplate: "")
            }
            a = a.trimmingCharacters(in: .whitespacesAndNewlines)
            if !a.isEmpty, !out.contains(a) { out.append(a) }
        }
        return out
    }

    // MARK: zip 与 XML

    private func extractEntry(_ entry: Entry, from archive: Archive) -> Data? {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try archive.extract(entry, to: tmp)
            let data = try? Data(contentsOf: tmp)
            try? FileManager.default.removeItem(at: tmp)
            return data
        } catch {
            return nil
        }
    }

    /// xl/sharedStrings.xml → [字符串]
    static func parseSharedStrings(_ data: Data) -> [String] {
        let delegate = SharedStringsXMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.strings
    }

    private final class SharedStringsXMLParser: NSObject, XMLParserDelegate {
        var strings: [String] = []
        private var current = ""
        private var inSI = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
            if name == "si" { inSI = true; current = "" }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inSI { current += string }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
            if name == "si" { strings.append(current); inSI = false }
        }
    }

    /// 工作表 → 二维字符串表（按单元格引用定位列，空单元格不串列）
    static func parseSheet(_ data: Data, sharedStrings: [String]) -> [[String]] {
        let delegate = SheetXMLParser(sharedStrings: sharedStrings)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.rows
    }

    private final class SheetXMLParser: NSObject, XMLParserDelegate {
        let sharedStrings: [String]
        var rows: [[String]] = []

        private var currentRow: [String?] = []
        private var currentCol = 0
        private var cellType = ""
        private var cellText = ""
        private var inCell = false
        private var inInlineText = false

        init(sharedStrings: [String]) {
            self.sharedStrings = sharedStrings
        }

        /// "BC12" → 列号（0-based）
        private func column(of ref: String?) -> Int {
            guard let ref else { return currentCol }
            var idx = 0
            for ch in ref.uppercased() {
                if let scalar = ch.asciiValue, scalar >= 65, scalar <= 90 {
                    idx = idx * 26 + Int(scalar - 65 + 1)
                } else { break }
            }
            return max(idx - 1, 0)
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            switch name {
            case "row":
                currentRow = Array(repeating: nil, count: 64)
            case "c":
                inCell = true
                cellType = attributeDict["t"] ?? ""
                cellText = ""
                currentCol = column(of: attributeDict["r"])
            case "is":
                inInlineText = true
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inCell { cellText += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
            switch name {
            case "c":
                inCell = false
                inInlineText = false
                var value = cellText
                if cellType == "s", let i = Int(cellText), i >= 0, i < sharedStrings.count {
                    value = sharedStrings[i]
                }
                if currentCol < currentRow.count { currentRow[currentCol] = value }
                cellText = ""
            case "row":
                let compact = currentRow.map { $0 ?? "" }
                if compact.contains(where: { !$0.isEmpty }) { rows.append(compact) }
                currentRow = []
            default:
                break
            }
        }
    }
}
