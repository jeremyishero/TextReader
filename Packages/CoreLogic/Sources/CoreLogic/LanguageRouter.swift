import Foundation

// MARK: - 语言/文字判定（纯 Foundation，可在 CI 上单测）

/// v1 支持三类朗读语言：简体中文、繁体中文、英文。
public enum ScriptLanguage: String, CaseIterable, Codable {
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case english = "en"
}

/// 按字符统计判定一段文本所属语言，供朗读时自动切换声音。
/// 规则：
/// 1. 拉丁字母占比显著高于汉字 → 英文；
/// 2. 否则统计「繁体独有字 / 简体独有字」出现次数，多者为繁/简；
/// 3. 两类均无特征字或打平 → 默认简体。
public struct LanguageRouter {
    public init() {}

    /// 繁体独有特征字（在简体文本中几乎不会出现）
    static let traditionalOnly: Set<Character> = [
        "們","這","說","對","開","關","頭","裡","裏","東","車","馬","鳥","書","長","門","見","貝","頁","風","飛",
        "雲","電","話","學","國","會","來","時","間","體","點","麼","後","臺","灣","龍","鳳","愛","樣","聽","覺",
        "經","過","還","進","遠","運","連","週","歲","處","帶","廣","慶","應","該","證","識","議","豐","腦","髮",
        "飯","館","驚","願","顧","錢","銀","報","紙","讓","變","邊","裝","觀","觸","衛","壞","聲","響","轉","醫",
        "藥","廢","發","無","為","與","專","業","員","團","區","歷","歸","當","發","誰","請","謝","錯","誤","離"
    ]
    /// 简体独有特征字（在繁体文本中几乎不会出现）
    static let simplifiedOnly: Set<Character> = [
        "们","这","说","对","开","关","头","里","东","车","马","鸟","书","长","门","见","贝","页","风","飞",
        "云","电","话","学","国","会","来","时","间","体","点","么","后","台","龙","凤","爱","样","听","觉",
        "经","过","还","进","远","运","连","周","岁","处","带","广","庆","应","该","证","识","议","丰","脑","发",
        "饭","馆","惊","愿","顾","钱","银","报","纸","让","变","边","装","观","触","卫","坏","声","响","转","医",
        "药","废","无","为","与","专","业","员","团","区","历","归","当","谁","请","谢","错","误","离"
    ]

    public func detect(_ text: String) -> ScriptLanguage {
        var han = 0, latin = 0, trad = 0, simp = 0
        for ch in text.unicodeScalars {
            if (0x4E00...0x9FFF).contains(ch.value) || (0x3400...0x4DBF).contains(ch.value) {
                han += 1
                let c = Character(ch)
                if Self.traditionalOnly.contains(c) { trad += 1 }
                if Self.simplifiedOnly.contains(c) { simp += 1 }
            } else if (ch.value >= 65 && ch.value <= 90) || (ch.value >= 97 && ch.value <= 122) {
                latin += 1
            }
        }
        // 英文判定：拉丁字母多于汉字（中英混排时以多数为准）
        if latin > han { return .english }
        if han == 0 { return latin > 0 ? .english : .zhHans }
        if trad > simp { return .zhHant }
        return .zhHans
    }
}
