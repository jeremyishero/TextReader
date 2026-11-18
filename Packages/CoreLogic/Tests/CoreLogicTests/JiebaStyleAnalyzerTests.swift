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
}
