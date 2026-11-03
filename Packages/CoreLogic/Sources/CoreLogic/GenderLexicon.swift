import Foundation

/// 角色性别（用于声音分配）。neutral 表示中性声，用于无法判定或旁白。
public enum Gender: String, Codable, CaseIterable, Sendable {
    case male
    case female
    case neutral
}

/// 多角度性别打分：male/female 各自累加，最终按阈值投票，差异不足则判中性以降低误判。
public struct GenderScore {
    public var male: Int = 0
    public var female: Int = 0

    public init() {}

    public mutating func add(_ g: Gender, weight: Int = 1) {
        switch g {
        case .male: male += weight
        case .female: female += weight
        case .neutral: break
        }
    }

    /// 综合投票：差异需超过 threshold 才判定，否则返回 neutral（保守，避免误判）。
    /// 默认 threshold=0，即 male>female 即判男（单点信号也算；与称谓/关系词加权叠加后更稳）。
    public func result(threshold: Int = 0) -> Gender {
        if male == 0 && female == 0 { return .neutral }
        if male - female > threshold { return .male }
        if female - male > threshold { return .female }
        return .neutral
    }
}

/// 中文性别判定词表：姓名用字、称谓、关系词。多角度合并投票，单点误判可被其他信号纠正。
public struct GenderLexicon {

    /// 百家姓常用子集（用于校验「说话人」是一个姓名而非普通词）。
    public static let surnames: Set<String> = {
        let s = "赵钱孙李周吴郑王冯陈褚卫蒋沈韩杨朱秦尤许何吕施张孔曹严华金魏陶姜戚谢邹喻柏水窦章云苏潘葛奚范彭郎鲁韦昌马苗凤花方俞任袁柳酆鲍史唐费廉岑薛雷贺倪汤滕殷罗毕郝邬安常乐于时傅皮卞齐康伍余元卜顾孟平黄和穆萧尹姚邵湛汪祁毛禹狄米贝明臧计伏成戴谈宋茅庞熊纪舒屈项祝董梁杜阮蓝闵席季麻强贾路娄危江童颜郭梅盛林刁钟徐邱骆高夏蔡田樊胡凌霍万柯卢莫房裘缪干解应宗丁宣贲邓郁单杭洪包诸左石崔吉钮龚程嵇邢滑裴陆荣翁荀羊甄家封芮储靳邝牧靳燕寇富禄越师巩厍聂晁勾敖融冷訾辛阚那简饶空曾毋沙乜养鞠须丰巢关蒯相查后荆红游竺权逯盖益桓公岳帅缑亢况郜亢仰晁"
        return Set(s.map { String($0) })
    }()

    /// 给定名常用字（偏男）
    public static let maleNameChars: Set<Character> = Set(Array("伟强刚勇军杰涛明超峰毅宇浩凯鹏斌波辉龙飞磊旭昊辰轩睿铭铠铮铁雄豪俊彦宏志国华德文建永昌盛邦振耀晨阳星海山岩松柏锋剑彪焱烁烽硕钦钧锐霖哲熙渊帅飒岩川"))
    /// 给定名常用字（偏女）
    public static let femaleNameChars: Set<Character> = Set(Array("婷娟秀丽燕玲芳娜静淑惠美倩雪梅兰竹菊莲茹薇雅婉馨怡悦欣彤丹琳璐瑾萱萌蕊婧韵娇萍霞月盈依曼柔诗梦琪瑶嫣晴芸菲茜露霜仪凤怡姗嫒霓翩舜娥姝娆倩妤"))

    /// 称谓/敬语 → 性别
    public static let titleHints: [String: Gender] = [
        "姑娘": .female, "小姐": .female, "娘子": .female, "丫鬟": .female, "丫头": .female,
        "秀女": .female, "妃": .female, "皇后": .female, "太后": .female, "夫人": .female,
        "妾": .female, "妻": .female, "女儿": .female, "姐妹": .female, "姊": .female,
        "妹": .female, "嫂": .female, "婆": .female, "姑": .female, "公主": .female,
        "郡主": .female, "女侠": .female, "女王": .female, "仙子": .female, "淑女": .female,
        "公子": .male, "少爷": .male, "老爷": .male, "王爷": .male, "相公": .male,
        "郎君": .male, "丈夫": .male, "兄": .male, "哥": .male, "叔": .male,
        "伯": .male, "父": .male, "舅": .male, "少侠": .male, "大侠": .male,
        "壮士": .male, "将军": .male, "皇帝": .male, "仙君": .male, "公子爷": .male,
        "书生": .male, "少年": .male, "汉子": .male, "老爷子": .male
    ]

    /// 关系词 → 性别
    public static let relationHints: [String: Gender] = [
        "妻": .female, "母": .female, "姐": .female, "妹": .female, "嫂": .female,
        "姑": .female, "婆": .female, "姨": .female, "婶": .female, "媳": .female,
        "女儿": .female, "姊": .female, "娘": .female, "妈": .female, "妇": .female,
        "夫": .male, "父": .male, "兄": .male, "哥": .male, "叔": .male,
        "伯": .male, "舅": .male, "丈": .male, "婿": .male, "郎": .male,
        "爹": .male, "爸": .male, "子": .male, "弟": .male, "爷": .male
    ]

    /// 根据姓名（或含称谓的字符串）用「名字用字」打分。
    public static func score(for name: String) -> GenderScore {
        var s = GenderScore()
        for c in name {
            if maleNameChars.contains(c) { s.add(.male) }
            if femaleNameChars.contains(c) { s.add(.female) }
        }
        return s
    }

    /// 从含称谓文本中提取性别提示（命中任一即返回）。
    public static func titleGender(_ text: String) -> Gender? {
        for (k, v) in titleHints where text.contains(k) { return v }
        return nil
    }

    /// 从含关系词文本中提取性别提示。
    public static func relationGender(_ text: String) -> Gender? {
        for (k, v) in relationHints where text.contains(k) { return v }
    }

    /// 取名字首字判断是否为常见姓氏（软校验，用于过滤非姓名 token）。
    public static func isLikelySurname(_ char: Character) -> Bool {
        surnames.contains(String(char))
    }
}
