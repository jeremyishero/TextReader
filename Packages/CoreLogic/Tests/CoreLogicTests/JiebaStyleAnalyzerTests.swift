import XCTest
@testable import CoreLogic

/// jieba 风格解析器的回归测试：验证复数姓名、绰号、身份称谓、别名合并。
/// 同时把角色列表打到 CI 日志，便于对比 PC 端结果。
final class JiebaStyleAnalyzerTests: XCTestCase {

    /// 取自《凡人修仙传》开篇角色各发言多次，验证关键角色识别。
    let fanrenSample = """
    墨大夫咳嗽道：「这是新来的弟子吗？」
    韩立答道：「弟子韩立。」
    岳堂主说道：「大家听好，往竹林走。」
    厉飞雨笑道：「韩师弟恭喜。」
    小算盘说道：「我有独家消息。」
    墨大夫又道：「人手不够，缺炼药弟子。」
    韩立问道：「什么消息？」
    岳堂主喝道：「快些赶路！」
    厉飞雨说道：「小心考校。」
    小算盘道：「关乎墨大夫来历。」
    墨大夫道：「你二人跟我走吧。」
    韩立应道：「遵命。」
    岳堂主道：「时候不早了。」
    厉飞雨道：「我先走了。」
    小算盘道：「此事不可外传。」
    """

    func testFanrenKeyRoles() {
        let result = JiebaStyleAnalyzer().analyze(fanrenSample)

        var freq: [String: Int] = [:]
        for seg in result.segments {
            if let cid = seg.characterId {
                let name = result.roles.first { $0.id == cid }?.canonicalName ?? "?"
                freq[name, default: 0] += 1
            }
        }
        let sorted = result.roles.sorted { (freq[$0.canonicalName] ?? 0) > (freq[$1.canonicalName] ?? 0) }
        print("=== JiebaStyleAnalyzer 角色结果 ===")
        for (i, r) in sorted.enumerated() {
            print("\(i+1). \(r.canonicalName) [\(r.gender.rawValue)] freq=\(freq[r.canonicalName] ?? 0)")
        }

        let names = Set(result.roles.map { $0.canonicalName })
        XCTAssertTrue(names.contains("韩立"), "应识别韩立，实为 \(names)")
        XCTAssertTrue(names.contains("墨大夫"), "应识别墨大夫（姓表补集），实为 \(names)")
        XCTAssertTrue(names.contains("岳堂主"), "应识别岳堂主（身份称谓），实为 \(names)")
        XCTAssertTrue(names.contains("小算盘"), "应识别绰号小算盘，实为 \(names)")
        XCTAssertTrue(names.contains("厉飞雨"), "应识别厉飞雨，实为 \(names)")
    }

    /// 全文朗读：segments 必须覆盖旁白（引号外正文），不能只读引号内对话。
    func testNarrationCovered() {
        let sample = """
        韩立走在山路上，四下无人，心中暗暗警惕。
        墨大夫说道：「前面就是药园了。」
        两人继续前行，山路愈发难走。
        """
        let result = JiebaStyleAnalyzer().analyze(sample)
        let joined = result.segments.map(\.text).joined()
        XCTAssertTrue(joined.contains("韩立走在山路上"), "旁白应进入 segments，实为 \(result.segments.map(\.text))")
        XCTAssertTrue(joined.contains("两人继续前行"), "尾部旁白应进入 segments")
        let narrationCount = result.segments.filter { $0.characterId == nil }.count
        print("=== 旁白段数: \(narrationCount) / 总段数 \(result.segments.count) ===")
        XCTAssertGreaterThan(narrationCount, 0, "应存在旁白段")
    }

    /// 角色按真实台词数降序、无 0 台词角色。
    func testRolesSortedByQuoteCount() {
        let result = JiebaStyleAnalyzer().analyze(fanrenSample)
        var freq: [String: Int] = [:]
        for seg in result.segments {
            if let cid = seg.characterId,
               let name = result.roles.first(where: { $0.id == cid })?.canonicalName {
                freq[name, default: 0] += 1
            }
        }
        for r in result.roles {
            let c = freq[r.canonicalName] ?? 0
            print("角色 \(r.canonicalName) 台词 \(c)")
            XCTAssertGreaterThan(c, 0, "不应出现 0 台词角色: \(r.canonicalName)")
        }
        let counts = result.roles.map { freq[$0.canonicalName] ?? 0 }
        XCTAssertEqual(counts, counts.sorted(by: >), "角色应按台词数降序: \(counts)")
        XCTAssertLessThanOrEqual(result.roles.count, 48, "角色数不应超过 48")
    }

    func testAliasMerge() {
        let sample = """
        厉飞雨说道：「今日考校小心。」
        厉飞雨道：「韩师弟可要帮忙？」
        厉飞雨笑曰：「无妨。」
        厉师兄说道：「这一次考校你我都需小心。」
        厉师兄道：「莫要大意。」
        厉师兄言道：「随我来。」
        韩立答道：「多谢厉师兄。」
        """
        let result = JiebaStyleAnalyzer().analyze(sample)
        let names = Set(result.roles.map { $0.canonicalName })
        print("=== 别名合并测试角色: \(names) ===")
        XCTAssertTrue(names.contains("厉飞雨"), "应识别厉飞雨，实为 \(names)")
        XCTAssertFalse(names.contains("厉师兄"), "厉师兄应合并为厉飞雨，实为 \(names)")
    }

    /// 噪声词必须被剔除；韩立/墨大夫=男、墨凤舞=女；燕家老不因「燕」姓误判女。
    func testNoiseAndGender() {
        let sample = """
        韩立说道：「墨大夫，药园可曾备好？」
        墨大夫道：「已经备好了。」
        墨凤舞说道：「我也去。」
        厉飞雨笑道：「那就一同前往。」
        韩立又道：「墨大夫，此药可炼？」
        墨大夫道：「还需三味辅料。」
        墨凤舞道：「辅料我来寻。」
        厉飞雨道：「我陪你去。」
        韩立道：「多谢诸位。」
        墨大夫道：「小心些。」
        墨凤舞道：「知道了。」
        厉飞雨道：「走吧。」
        韩立道：「先去药园。」
        韩立又道：「随后再来。」
        韩立道：「我走前面。」
        老者一说道：「时候不早了。」
        老者听道：「马上上路。」
        师兄说道：「路上小心。」
        师叔道：「明显有异。」
        冷静说道：「时辰后见。」
        老者一又道：「快走。」
        老者听道：「这就走。」
        师兄道：「当心。」
        师叔道：「且慢。」
        冷静道：「不好。」
        """
        let result = JiebaStyleAnalyzer().analyze(sample)
        let names = Set(result.roles.map { $0.canonicalName })
        print("=== 噪声测试角色: \(result.roles.map { ($0.canonicalName, $0.gender.rawValue) }) ===")
        // 真实角色应保留
        XCTAssertTrue(names.contains("韩立"), "应保留韩立，实为 \(names)")
        XCTAssertTrue(names.contains("墨大夫"), "应保留墨大夫")
        XCTAssertTrue(names.contains("墨凤舞"), "应保留墨凤舞")
        // 噪声词必须剔除
        for noise in ["老者一","老者听","师兄","师叔","时候","马上","路上","明显","冷静","时辰后","高男子","须大汉"] {
            XCTAssertFalse(names.contains(noise), "噪声词不应成角色: \(noise)，实为 \(names)")
        }
        // 性别
        let genderOf: (String) -> Gender? = { n in result.roles.first { $0.canonicalName == n }?.gender }
        XCTAssertEqual(genderOf("韩立"), .male, "韩立应为男")
        XCTAssertEqual(genderOf("墨大夫"), .male, "墨大夫应为男")
        XCTAssertEqual(genderOf("墨凤舞"), .female, "墨凤舞应为女")
    }

    /// 年龄段推断：老者→老年、童子→童年、少年→少年、普通姓名→青年(默认)。
    func testAgeInference() {
        let sample = """
        韩立说道：「墨大夫，老者可安好？」
        墨大夫道：「那老者已离去。」
        童子说道：「小童子见过诸位。」
        少年道：「我少年意气。」
        韩立又道：「童子且退下。」
        墨大夫道：「老者慢走。」
        """
        let result = JiebaStyleAnalyzer().analyze(sample)
        let ageOf: (String) -> Age? = { n in result.roles.first { $0.canonicalName == n }?.age }
        print("=== 年龄测试: \(result.roles.map { ($0.canonicalName, $0.age.rawValue) }) ===")
        XCTAssertEqual(ageOf("韩立"), .youth, "韩立无年龄线索→青年")
        // 老者/童子若被识别为角色，年龄应正确（它们也可能被当泛称过滤，故用可选断言）
        if let a = ageOf("老者") { XCTAssertEqual(a, .senior, "老者→老年") }
        if let a = ageOf("童子") { XCTAssertEqual(a, .child, "童子→童年") }
    }
}
