import XCTest
import CoreLogic
import ZIPFoundation

final class CoreLogicTests: XCTestCase {

    /// 一段用于验证的中文小说片段：
    /// 林浩(男) / 苏婷(女)，并通过「林兄」「那少年」「她」等不同称呼指向同一角色。
    let sample = """
    第一章 英雄初现

    林浩走在街上，神情郁郁。苏婷姑娘迎面走来。

    林浩笑道：「苏姑娘，今日可好？」

    苏婷微微一笑：「托林大哥的福，尚可。」

    那少年站在一旁，怒道：「你们聊，我先走了。」

    她叹了口气：「这世道，真是难。」

    林兄劝道：「莫要灰心。」
    """

    func testGenderAndCoreference() {
        let result = CharacterAnalyzer().analyze(sample)

        // 应只识别出两个角色：林浩、苏婷
        XCTAssertEqual(result.roles.count, 2, "应合并为 2 个角色，实为 \(result.roles.map { $0.canonicalName })")

        let lin = result.roles.first { $0.canonicalName == "林浩" }
        let su = result.roles.first { $0.canonicalName == "苏婷" }

        XCTAssertNotNil(lin, "应存在角色 林浩")
        XCTAssertNotNil(su, "应存在角色 苏婷")

        // 多角度性别判定
        XCTAssertEqual(lin?.gender, .male, "林浩应判定为男（名字用字『浩』+『林兄』称谓）")
        XCTAssertEqual(su?.gender, .female, "苏婷应判定为女（名字用字『婷』）")

        // 别名/代词/描述词合并到同一角色
        XCTAssertTrue(lin?.aliases.contains("林兄") == true, "『林兄』应合并进 林浩")
        XCTAssertTrue(lin?.aliases.contains("那少年") == true, "『那少年』应合并进 林浩")
        XCTAssertTrue(su?.aliases.contains("她") == true, "代词『她』应合并进 苏婷")
    }

    func testEmotionDetection() {
        let result = CharacterAnalyzer().analyze(sample)

        let joy = result.segments.first { $0.text.contains("苏姑娘，今日可好") }
        XCTAssertEqual(joy?.emotion, .joy, "『笑道』应识别为喜")

        let anger = result.segments.first { $0.text.contains("你们聊，我先走了") }
        XCTAssertEqual(anger?.emotion, .anger, "『怒道』应识别为怒")

        let sorrow = result.segments.first { $0.text.contains("这世道，真是难") }
        XCTAssertEqual(sorrow?.emotion, .sorrow, "『叹了口气』应识别为哀")
    }

    func testNarrationIsNeutral() {
        let result = CharacterAnalyzer().analyze(sample)
        let first = result.segments.first
        XCTAssertNil(first?.characterId, "段首旁白不应有说话人")
        XCTAssertEqual(first?.emotion, .neutral)
    }

    func testTxtExtraction() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        try sample.write(to: tmp, atomically: true, encoding: .utf8)
        let text = TextExtractor().extract(from: tmp)
        XCTAssertNotNil(text)
        XCTAssertTrue(text?.contains("林浩") == true)
    }

    func testDocxExtraction() throws {
        // 用 ZIPFoundation 构造一个最小 docx，验证 DocxParser
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("docx")
        var archive = Archive(url: tmp, accessMode: .create)
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
            <w:p><w:r><w:t>你好世界</w:t></w:r></w:p>
            <w:p><w:r><w:t>第二行文本</w:t></w:r></w:p>
          </w:body>
        </w:document>
        """
        try archive?.addEntry(with: "word/document.xml", data: Data(xml.utf8))

        let text = DocxParser().extractText(from: tmp)
        XCTAssertNotNil(text, "docx 应能被解析")
        XCTAssertTrue(text?.contains("你好世界") == true)
        XCTAssertTrue(text?.contains("第二行文本") == true)
    }

    func testChunker() {
        let long = String(repeating: "这是一句话。", count: 50)
        let chunks = TextChunker().chunk(long, maxLength: 60)
        XCTAssertFalse(chunks.isEmpty)
        for c in chunks {
            XCTAssertLessThanOrEqual(c.count, 70, "分块不应过长")
        }
    }
}
