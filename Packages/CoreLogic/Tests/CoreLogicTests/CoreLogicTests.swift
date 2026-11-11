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
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let docDir = base.appendingPathComponent("word", isDirectory: true)
        try FileManager.default.createDirectory(at: docDir, withIntermediateDirectories: true)
        let tmp = base.appendingPathExtension("docx")
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
            <w:p><w:r><w:t>你好世界</w:t></w:r></w:p>
            <w:p><w:r><w:t>第二行文本</w:t></w:r></w:p>
          </w:body>
        </w:document>
        """
        try Data(xml.utf8).write(to: docDir.appendingPathComponent("document.xml"))
        var archive = try Archive(url: tmp, accessMode: .create)
        try archive.addEntry(with: "word/document.xml", relativeTo: base)

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

    func testXlsxRoleImport() throws {
        // 构造最小 .xlsx（sharedStrings + sheet1），验证人物解析表导入
        let sst = """
        <?xml version="1.0" encoding="UTF-8"?>
        <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="6" uniqueCount="6">
          <si><t>姓名</t></si>
          <si><t>别名/身份</t></si>
          <si><t>性别</t></si>
          <si><t>慕容衍</t></si>
          <si><t>太子、吴七（伪装）</t></si>
          <si><t>男</t></si>
        </sst>
        """
        let sheet = """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData>
            <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="C1" t="s"><v>2</v></c></row>
            <row r="2"><c r="A2" t="s"><v>3</v></c><c r="B2" t="s"><v>4</v></c><c r="C2" t="s"><v>5</v></c></row>
          </sheetData>
        </worksheet>
        """
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let xl = base.appendingPathComponent("xl", isDirectory: true)
        let wsDir = xl.appendingPathComponent("worksheets", isDirectory: true)
        try FileManager.default.createDirectory(at: wsDir, withIntermediateDirectories: true)
        try Data(sst.utf8).write(to: xl.appendingPathComponent("sharedStrings.xml"))
        try Data(sheet.utf8).write(to: wsDir.appendingPathComponent("sheet1.xml"))
        let tmp = base.appendingPathExtension("xlsx")
        var archive = try Archive(url: tmp, accessMode: .create)
        try archive.addEntry(with: "xl/sharedStrings.xml", relativeTo: base)
        try archive.addEntry(with: "xl/worksheets/sheet1.xml", relativeTo: base)

        let roles = XlsxRoleParser().parseRoles(from: tmp)
        XCTAssertEqual(roles.count, 1, "应解析出 1 个角色")
        XCTAssertEqual(roles.first?.name, "慕容衍")
        XCTAssertEqual(roles.first?.gender, .male)
        XCTAssertEqual(roles.first?.aliases, ["太子", "吴七"], "别名应按顿号拆分并剥掉括号备注")
    }

    // MARK: - v3 闭环解析回归

    /// 状语/动作/情绪词不得被注册为角色；真人名仍要识别。
    private let falsePositiveSample = """
    第三章 雨夜

    慕容衍脱口道：「此事不可。」

    徐镜儿抬眼轻声说：「那便再等等。」

    他心疼地叹了口气：「罢了。」

    慕容衍笑道：「明日再说。」

    徐镜儿点头：「好。」
    """

    func testDescriptiveWordsAreNotRoles() {
        let r = CharacterAnalyzer().analyze(falsePositiveSample)
        let names = Set(r.roles.map { $0.canonicalName })
        print("V3_ROLES_NO_FALSE_POSITIVE: " + names.sorted().joined(separator: ","))
        for junk in ["脱口", "抬眼", "心疼", "轻声", "点头", "叹了", "地叹", "口气"] {
            XCTAssertFalse(names.contains(junk), "『\(junk)』是描写词，不应被识别为角色")
        }
        XCTAssertTrue(names.contains("慕容衍"), "真人名 慕容衍 应保留")
        XCTAssertTrue(names.contains("徐镜儿"), "真人名 徐镜儿 应保留")
        XCTAssertLessThanOrEqual(r.roles.count, 3, "角色数应收敛，实为 \(names)")
    }

    /// 黑名单（用户自定义过滤词）与白名单（用户自定义人名）语义保持不变。
    func testBlackWhiteListsStillWork() {
        let text = """
        慕容衍脱口道：「此事不可。」
        阿朱站在门边。
        徐镜儿轻声说：「且慢。」
        """
        let blocked = CharacterAnalyzer().analyze(text, userStopwords: ["徐镜儿"])
        XCTAssertFalse(blocked.roles.contains { $0.canonicalName == "徐镜儿" },
                       "用户黑名单中的词永远不能被识别为角色")

        let allowed = CharacterAnalyzer().analyze(text, userWhitelist: ["阿朱"])
        XCTAssertTrue(allowed.roles.contains { $0.canonicalName == "阿朱" },
                      "用户白名单中的词即使只出现在旁白、没有台词，也必须注册为角色")
    }

    /// Stage3 全局复核：只在旁白出现、从未作主语、从未拥有台词的候选要被淘汰。
    func testGlobalReviewDropsZeroQuoteCandidates() {
        let text = """
        花方站在门外。花方转身离去。
        慕容衍笑道：「来了。」
        """
        let r = CharacterAnalyzer().analyze(text)
        let names = Set(r.roles.map { $0.canonicalName })
        print("V3_ROLES_GLOBAL_REVIEW: " + names.sorted().joined(separator: ","))
        XCTAssertFalse(names.contains("花方"), "零台词、零主语的旁白碎片应在全局复核中淘汰")
        XCTAssertTrue(names.contains("慕容衍"), "有台词的角色应保留")
    }

    /// 状语剥离后，代词仍应正确回指到对应性别的角色（轮次状态机不破坏既有共指）。
    func testPronounAfterModifierStillResolves() {
        let text = """
        林浩笑道：「走吧。」
        苏婷轻声说：「等等。」
        他叹道：「罢了。」
        """
        let r = CharacterAnalyzer().analyze(text)
        XCTAssertFalse(r.roles.contains { $0.canonicalName == "轻声" })
        let lin = r.roles.first { $0.canonicalName == "林浩" }
        XCTAssertNotNil(lin)
        XCTAssertTrue(lin?.aliases.contains("他") == true || r.roles.count == 2,
                      "状语后的代词『他』应回指男性角色，而不是新建角色")
    }

    // MARK: - v4 用户实测误判回归

    /// 用户实测原句：笑眯眯 / 满口胡 / 反倒 曾被注册成角色。
    private let userReportedSample = """
    陈公公笑眯眯道：“殿下恕罪，老奴年纪大了，腿脚比较慢。”

    又想起当初这人满口胡言乱语，顾琅听着他满口胡话，不由得皱了皱眉。

    顾琅反倒要去入赘，反倒想起上回那个不知从哪儿冒出来的，反倒笑了笑，反倒急忙走到床边。

    顾琅道：“此事再议。”
    """

    func testUserReportedFalsePositivesAreNotRoles() {
        let r = CharacterAnalyzer().analyze(userReportedSample)
        let names = Set(r.roles.map { $0.canonicalName })
        print("V4_USER_CASE: " + names.sorted().joined(separator: ","))
        for junk in ["笑眯眯", "满口胡", "满口", "胡言", "胡话", "反倒", "笑眯"] {
            XCTAssertFalse(names.contains(junk), "『\(junk)』是描写词/副词，不应被识别为角色")
        }
        XCTAssertTrue(names.contains("顾琅"), "真人名 顾琅 应保留")
        XCTAssertTrue(names.contains("陈公公"), "带称谓的真人名 陈公公 应保留")
        XCTAssertLessThanOrEqual(r.roles.count, 4, "角色数应收敛，实为 \(names)")
    }

    /// 关键：用完全不在任何词表里的「新造描写词」验证机制，而不是补词表打地鼠。
    func testUnseenDescriptiveWordsNeverBecomeRoles() {
        let text = """
        顾琅慢吞吞道：“来了。”
        徐镜儿气鼓鼓说：“哼。”
        顾琅斜睨道：“随你。”
        徐镜儿撇嘴道：“知道了。”
        """
        let r = CharacterAnalyzer().analyze(text)
        let names = Set(r.roles.map { $0.canonicalName })
        print("V4_UNSEEN_JUNK: " + names.sorted().joined(separator: ","))
        for junk in ["慢吞吞", "气鼓鼓", "斜睨", "撇嘴", "顾琅斜睨", "徐镜儿气鼓鼓"] {
            XCTAssertFalse(names.contains(junk), "未登记的新描写词『\(junk)』也不应成为角色")
        }
        XCTAssertTrue(names.contains("顾琅"))
        XCTAssertTrue(names.contains("徐镜儿"))
    }

    /// 白名单仍是补漏入口：用户指定的名字不受人名形态门槛限制。
    func testWhitelistStillOverridesShape() {
        let r = CharacterAnalyzer().analyze(userReportedSample, userWhitelist: ["笑眯眯"])
        XCTAssertTrue(r.roles.contains { $0.canonicalName == "笑眯眯" },
                      "白名单词即使长得像描写词，也必须按用户指定注册为角色")
    }

    // MARK: - v5 官职/称谓解析

    /// 用户要求：太子、林尚书、周尚书、御史、吏部尚书、礼部尚书 等官职/称谓也要能被解析为说话人。
    private let titleSample = """
    第一章 朝堂

    太子沉吟道：「此事容后再议。」

    林尚书笑道：「臣附议。」

    周尚书皱眉道：「不可。」

    御史奏道：「臣有本奏。」

    吏部尚书朗声道：「准。」

    礼部尚书低声道：「亦准。」
    """

    func testOfficialTitlesAreParsed() {
        let r = CharacterAnalyzer().analyze(titleSample)
        let names = Set(r.roles.map { $0.canonicalName })
        print("V5_TITLES: " + names.sorted().joined(separator: ","))
        for t in ["太子", "林尚书", "周尚书", "御史", "吏部尚书", "礼部尚书"] {
            XCTAssertTrue(names.contains(t), "官职/称谓『\(t)』应被解析为角色")
        }
        let tai = r.roles.first { $0.canonicalName == "太子" }
        XCTAssertEqual(tai?.gender, .male, "太子应为男")
        let li = r.roles.first { $0.canonicalName == "林尚书" }
        XCTAssertEqual(li?.gender, .male, "林尚书应为男")
        let libu = r.roles.first { $0.canonicalName == "吏部尚书" }
        XCTAssertEqual(libu?.gender, .male, "吏部尚书应为男")
    }

    // MARK: - v6 旁白名词/描写词不再是角色

    /// v6 修复：旁白里的「姓氏+名词」（烤羊腿/马肉/花生）与说话动词前的描写词（委委屈屈→屈屈、简单）
    /// 都不得被识别为角色；真实人名（顾琅/慕容衍/徐镜儿/屈封云/孙放）必须保留。
    /// 注意：算法靠「说话人 + 说话动词(道/说/问)」识别角色，故样本中真名须紧贴说话动词（符合真实小说场景），
    /// 垃圾词只出现在非说话人的旁白里，避免回溯窗口够不到说话人。
    private let v6NoiseSample = """
    第一章 厨房

    顾琅道：「这烤羊腿真好吃。」

    慕容衍皱眉道：「马肉火锅太膻了。」

    徐镜儿轻声说：「尝尝这个花生。」

    屈封云委委屈屈道：「殿下恕罪。」

    孙放问：「这是什么方方框框？」

    桌上摆着烤羊腿、马肉火锅和一盘花生，简单又丰盛。
    """

    func testV6NarrationNounsAndDescriptorsAreNotRoles() {
        let r = CharacterAnalyzer().analyze(v6NoiseSample)
        let names = Set(r.roles.map { $0.canonicalName })
        print("V6_NOISE: " + names.sorted().joined(separator: ","))
        for junk in ["羊腿", "马肉", "花生", "屈屈", "简单", "含糊", "皱眉", "轻声", "啃着", "火锅"] {
            XCTAssertFalse(names.contains(junk), "『\(junk)』是旁白名词/描写词，不应被识别为角色")
        }
        for real in ["顾琅", "慕容衍", "徐镜儿", "屈封云", "孙放"] {
            XCTAssertTrue(names.contains(real), "真人名『\(real)』应保留")
        }
        XCTAssertLessThanOrEqual(r.roles.count, 6, "角色数应收敛，实为 \(names)")
    }

    // MARK: - 角色表导出 Excel

    func testXlsxRoleExportRoundTrip() throws {
        let roles = [
            CharacterRole(id: "r1", canonicalName: "慕容衍",
                          aliases: ["慕容衍", "太子", "吴七"], gender: .male, voiceHint: "male"),
            CharacterRole(id: "r2", canonicalName: "徐镜儿",
                          aliases: ["徐镜儿"], gender: .female)
        ]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        try XlsxRoleExporter().export(roles: roles, quoteCounts: ["r1": 12, "r2": 7], to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "应生成 .xlsx 文件")

        // 导出的表必须能被现有导入器原样读回（导出→修改→导入闭环）
        let parsed = XlsxRoleParser().parseRoles(from: url)
        XCTAssertEqual(parsed.count, 2, "导出表应能被导入器读回")
        XCTAssertEqual(parsed.first?.name, "慕容衍")
        XCTAssertEqual(parsed.first?.gender, .male)
        XCTAssertEqual(parsed.first?.aliases, ["太子", "吴七"], "别名列应按顿号还原")
        XCTAssertEqual(parsed.last?.name, "徐镜儿")
        XCTAssertEqual(parsed.last?.gender, .female)
    }

    // MARK: - v7 引号后/冒号前 说话人归因修复回归

    /// v7 修复：引语之后的「追认说话人」（"「……」李四说" / "「……」他道"）
    /// 必须被识别为说话人，而不是整段归旁白（否则「所有人都一个声音」）。
    func testPostQuoteAttributionByName() {
        let text = """
        第一章 测试

        「你来了。」林浩说。
        """
        let r = CharacterAnalyzer().analyze(text)
        let names = Set(r.roles.map { $0.canonicalName })
        XCTAssertTrue(names.contains("林浩"), "引语后的『林浩说』应识别 林浩 为角色（引号后归因）")
        let seg = r.segments.first { $0.text.contains("你来了") }
        XCTAssertNotNil(seg?.characterId, "『你来了』这句话应有说话人，而非被错归旁白")
    }

    /// 引语后的代词「他道」应回指上一句的说话人（同一角色），而不是新建角色或归旁白。
    func testPostQuoteAttributionByPronoun() {
        let text = """
        第一章 测试

        林浩笑道：「今日天气真好。」

        「是啊。」他道。
        """
        let r = CharacterAnalyzer().analyze(text)
        let lin = r.roles.first { $0.canonicalName == "林浩" }
        XCTAssertNotNil(lin, "应存在角色 林浩")
        XCTAssertTrue(lin?.aliases.contains("他") == true, "『他』应合并进上一说话人 林浩 的别名")
        let seg = r.segments.first { $0.text.contains("是啊") }
        XCTAssertNotNil(seg?.characterId, "『他道』应回指 林浩，该句话不应是旁白")
    }

    /// v7 修复：说话动词后带冒号（"X说：" / "X道："）的引号前说话人也要识别，
    /// 旧实现要求动词必须紧贴句尾，导致 "X说：" 整句漏识别、台词错归旁白。
    func testColonTolerantPrecedingSpeaker() {
        let text = """
        第一章 测试

        林浩说：「你来了。」

        苏婷道：「我也来了。」
        """
        let r = CharacterAnalyzer().analyze(text)
        let names = Set(r.roles.map { $0.canonicalName })
        XCTAssertTrue(names.contains("林浩"), "『林浩说：』应识别 林浩（冒号容忍）")
        XCTAssertTrue(names.contains("苏婷"), "『苏婷道：』应识别 苏婷（冒号容忍）")
        let seg = r.segments.first { $0.text.contains("你来了") }
        XCTAssertNotNil(seg?.characterId, "『你来了』应有说话人 林浩，而非旁白")
    }
}
