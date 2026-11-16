import Foundation
import ZIPFoundation

/// 把当前角色列表导出成 .xlsx「人物解析表」。
///
/// 表头与 `XlsxRoleParser` 完全兼容（姓名 / 别名·身份 / 性别），
/// 导出的文件可以用「从表格导入(.xlsx)」原样导回，形成「导出 → 修改 → 导入」闭环。
/// 额外附两列（台词数 / 声音）方便核对角色，导入时会被忽略。
public struct XlsxRoleExporter {

    public init() {}

    /// - Parameters:
    ///   - roles: 当前角色列表
    ///   - quoteCounts: 角色 id → 台词段数（可选，用于「台词数」列）
    ///   - url: 输出文件 URL（已存在则覆盖）
    public func export(roles: [CharacterRole], quoteCounts: [String: Int] = [:], to url: URL) throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("xlsx_export_" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        for dir in ["xl", "xl/worksheets", "_rels", "xl/_rels"] {
            try fm.createDirectory(at: base.appendingPathComponent(dir, isDirectory: true),
                                   withIntermediateDirectories: true)
        }

        // ---- 1) 表格内容 ----
        var rows: [[String]] = [["姓名", "别名/身份", "性别", "台词数", "声音"]]
        for role in roles {
            let aliases = role.aliases
                .filter { $0 != role.canonicalName }
                .joined(separator: "、")
            let g: String = role.gender.cn
            rows.append([
                role.canonicalName,
                aliases,
                g,
                String(quoteCounts[role.id] ?? 0),
                role.voiceHint ?? "默认"
            ])
        }

        // ---- 2) sharedStrings：每个单元格一条（不去重，最简单也最稳） ----
        let all = rows.flatMap { $0 }
        var sst = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="\(all.count)" uniqueCount="\(all.count)">
        """
        for value in all { sst += "<si><t>\(Self.escape(value))</t></si>" }
        sst += "</sst>"

        // ---- 3) worksheet ----
        let cols = ["A", "B", "C", "D", "E"]
        var sheet = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
        """
        var index = 0
        for (r, row) in rows.enumerated() {
            sheet += "<row r=\"\(r + 1)\">"
            for c in 0..<row.count {
                sheet += "<c r=\"\(cols[c])\(r + 1)\" t=\"s\"><v>\(index)</v></c>"
                index += 1
            }
            sheet += "</row>"
        }
        sheet += "</sheetData></worksheet>"

        // ---- 4) 最小 OPC 包 ----
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
        <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
        <Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>
        </Types>
        """
        let rootRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>
        """
        let workbook = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <sheets><sheet name="角色" sheetId="1" r:id="rId1"/></sheets>
        </workbook>
        """
        let workbookRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>
        </Relationships>
        """

        let files: [String: String] = [
            "[Content_Types].xml": contentTypes,
            "_rels/.rels": rootRels,
            "xl/workbook.xml": workbook,
            "xl/_rels/workbook.xml.rels": workbookRels,
            "xl/worksheets/sheet1.xml": sheet,
            "xl/sharedStrings.xml": sst
        ]
        for (path, xml) in files {
            try Data(xml.utf8).write(to: base.appendingPathComponent(path))
        }

        // ---- 5) 打成 .xlsx ----
        try? fm.removeItem(at: url)
        var archive = try Archive(url: url, accessMode: .create)
        for path in files.keys {
            try archive.addEntry(with: path, relativeTo: base)
        }
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(c)
            }
        }
        return out
    }
}
