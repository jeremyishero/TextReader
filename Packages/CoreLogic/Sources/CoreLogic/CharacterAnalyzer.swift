import Foundation

// MARK: - 分析产出模型

/// 书中被识别出的一个角色（可能由姓名、称谓、代词、描述词合并而来）。
public struct CharacterRole: Identifiable, Codable {
    public var id: String
    public var canonicalName: String      // 主名称（通常为出现频次最高的姓名）
    public var aliases: [String]          // 合并进来的所有称呼（林风/林兄/那少年/他…）
    public var gender: Gender             // 多角度投票得出
    public var voiceHint: String?         // "male" / "female" / "neutral"，App 端映射到 AVSpeechSynthesisVoice
    public init(id: String, canonicalName: String, aliases: [String], gender: Gender, voiceHint: String? = nil) {
        self.id = id
        self.canonicalName = canonicalName
        self.aliases = aliases
        self.gender = gender
        self.voiceHint = voiceHint
    }
}

/// 一段朗读内容：旁白(characterId=nil) 或 某角色(characterId) 的台词，带情绪标签。
public struct SpeechSegment: Identifiable, Codable {
    public var id: String
    public var text: String
    public var characterId: String?       // nil = 旁白
    public var emotion: Emotion
    public var position: Int
    public init(id: String, text: String, characterId: String?, emotion: Emotion, position: Int) {
        self.id = id
        self.text = text
        self.characterId = characterId
        self.emotion = emotion
        self.position = position
    }
}

/// 一次「整体解析」的完整结果。
public struct AnalysisResult: Codable {
    public var roles: [CharacterRole]
    public var segments: [SpeechSegment]
    public init(roles: [CharacterRole], segments: [SpeechSegment]) {
        self.roles = roles
        self.segments = segments
    }
}

// MARK: - 分析器

/// 离线启发式角色/性别/指代/情绪分析器。
/// 设计目标：纯 Foundation，可在云端 macOS CI 上 `swift test`，无需 iOS 框架。
///
/// v2 算法（两遍扫描 + 频次准入，大幅减少误判）：
/// 1. 先扫描全文统计：三字说话人候选出现次数 → 得出「长名」集合（出现 ≥2 次的三字名）。
/// 2. 旁白二字候选统计时，把长名在原文中出现的位置「占位」，避免把「屈封云」拆成「封云」「屈封」、
///    把「屈封云+动词」误切成「云坐」「云抬」等跨界碎片。
/// 3. 准入规则：二字名须旁白出现 ≥2 次；三字名须作为说话人出现 ≥2 次；四字候选一律拒绝；
///    是长名子串且出现次数明显更少的视为碎片拒绝。
/// 4. 候选清洗：剥尾部说话动词噪声、剥头部虚词、含虚词/处所后缀/停用词的一律拒绝。
public struct CharacterAnalyzer {

    /// 说话提示词（出现在引语前，用于定位说话人）。
    /// 含口语化说话动词（扯/嘀咕/嘟囔/念叨等），覆盖「慕容衍一边躲一边继续鬼扯，"…」这类动作引语。
    /// v3：严格说话动词。只有这些能触发「主语」捕获，修饰词不再混进来。
    static let speechVerbs = "说|道|曰|问|答|喊|叫|笑|叹|哭|应|回|劝|禀|奏|言|吟|呼|唤|喝|骂|斥|吼|咆哮|叱|扯|嘀咕|嘟囔|嘟哝|念叨|咕哝|嚷|吩咐|补充"
    /// v4：只在「引号前最后一个分句」的末尾触发的说话动词。
    /// 去掉极易嵌在普通词里的单字（言/曰/应/回/禀/奏…），
    /// 例如「满口胡言乱语」里的『言』不再被当成说话提示。
    static let strictSpeechVerbs = "说|道|问|答|喊|叫|笑|叹|哭|骂|吼|嚷|吩咐|嘀咕|嘟囔|嘟哝|念叨|咕哝|补充|冷哼|接口|应声"

    /// v3：状语/修饰词。出现在说话动词前只能作修饰，永远不能注册为人名；同时作为负向特征。
    static let speechModifiers: [String] = [
        "轻声", "低声", "高声", "厉声", "冷声", "沉声", "淡声", "小声", "大声", "冷笑",
        "大喝", "咬牙", "脱口", "抬眼", "心疼", "抬眸", "垂眸", "抬手", "低头", "抬头",
        "转身", "起身", "皱眉", "挑眉", "咬唇", "抿唇", "点头", "摇头", "开口", "出声",
        "接口", "应声", "轻笑", "低笑", "苦笑", "轻叹", "叹息", "呢喃", "喃喃", "低语",
        "沉吟", "微微", "缓缓", "默默", "渐渐", "轻轻", "慢慢", "匆匆", "猛地", "顿时",
        "瞬间", "忽然", "突然", "关切", "沙哑", "平静", "淡淡", "柔声", "急声", "连声",
        "低沉", "大声", "低声道", "轻声道"
    ]
    /// v3 Stage0：统计叙述里的状语修饰词（负向特征）
    static func modifiersIn(_ text: String) -> [String] {
        speechModifiers.filter { text.contains($0) }
    }
    // MARK: v4 人名形态证据
    // 旧做法：说话动词前的任意汉字串 → 清洗 → 频次 → 注册（所以任何新描写词都能混进来）。
    // 新做法：一个字符串要成为角色，必须自带「人名形态证据」，否则宁可把台词归旁白。
    /// 常见复姓：首字不在单姓表里的名字（慕容衍、上官…）靠它过关。
    static let compoundSurnames: [String] = [
        "慕容", "欧阳", "上官", "司马", "诸葛", "夏侯", "皇甫", "尉迟", "公孙", "长孙",
        "宇文", "独孤", "南宫", "西门", "东郭", "令狐", "端木", "澹台", "公羊", "百里",
        "呼延", "羊舌", "微生", "梁丘", "左丘", "轩辕", "钟离", "闻人", "万俟", "第五",
        "南门", "颛孙", "太史", "申屠", "仲孙", "司徒", "司空", "亓官", "鲜于", "闾丘"
    ]
    /// 非人名用字（器官 / 言语 / 动作 / 副词常用字）。
    /// 这是字级通用约束，不是针对「笑眯眯 / 满口胡 / 反倒」逐词打地鼠：
    /// 任何没见过的新描写词，只要由这些字构成就进不来。
    static let nonNameChars: Set<Character> = Set("口言语话反倒眯眼手脚脸声急忙忽突渐缓默轻慢沉淡扯斜睨瞥走跑抬转摇皱抿咬叹吞咽鼓撇瞧盯瞪哼喘愣怔晃闪扫抚摸捏握拽拉推挡拦退进站坐躺靠笑哭怒骂吵闹")

    /// 人名形态硬门槛：复姓 / 单姓开头、昵称前缀(阿·小·老)+姓氏、或用户白名单；
    /// 且不得含功能字、非人名用字、状语词、黑名单词。
    static func hasPersonNameShape(_ s: String, whitelist: Set<String>, blocked: Set<String>) -> Bool {
        if whitelist.contains(s) { return true }
        if blocked.contains(s) { return false }
        guard s.count >= 2, s.count <= 4 else { return false }
        if s.contains(where: { Self.funcChars.contains($0) || Self.nonNameChars.contains($0) }) { return false }
        if Self.speechModifiers.contains(s) { return false }
        // 复姓：复姓 + 1~2 字名（慕容衍 / 欧阳娜娜）
        for cs in Self.compoundSurnames where s.hasPrefix(cs) {
            return s.count >= cs.count + 1 && s.count <= cs.count + 2
        }
        let chars = Array(s)
        // 单姓最多「姓 + 2 字」，避免把「顾琅斜睨」整串当成一个名字
        if GenderLexicon.surnames.contains(String(chars[0])) { return s.count <= 3 }
        if chars.count >= 2, "阿小老".contains(chars[0]),
           GenderLexicon.surnames.contains(String(chars[1])) { return s.count <= 3 }
        return false
    }

    /// 从「说话动词前的汉字串」里挑出最像人名的子串。
    /// v5：以姓/复姓/阿小老为锚点，仅沿「名用字」向右延伸，遇第一个非名用字即止——
    /// 「顾琅垂眼」→「顾琅」（垂不是名用字，立即截断，绝不会把动词并进名字）；
    /// 「陈公公笑眯眯」→「陈公公」（保住真主语）；「反倒笑了」→ nil（台词归旁白）。
    static func extractPersonName(from raw: String, whitelist: Set<String>, blocked: Set<String>) -> String? {
        let chars = Array(raw)
        guard !chars.isEmpty else { return nil }
        var best: String? = nil
        for i in 0..<chars.count {
            let remainder = String(chars[i...])
            var compLen = 0
            for cs in Self.compoundSurnames where remainder.hasPrefix(cs) { compLen = cs.count; break }
            var j = i
            if compLen > 0 {
                j = i + compLen
                while j < chars.count, Self.isNameChar(chars[j]), (j - i) < compLen + 2 { j += 1 }
            } else if Self.isNameChar(chars[i]) {
                j = i + 1
                while j < chars.count, Self.isNameChar(chars[j]), (j - i) < 3 { j += 1 }
            } else {
                continue
            }
            let runEnd = j
            guard runEnd - i >= 2 else { continue }
            let maxLen = min(4, runEnd - i)
            for len in stride(from: maxLen, through: 2, by: -1) {
                let cand = String(chars[i..<(i + len)])
                if Self.hasPersonNameShape(cand, whitelist: whitelist, blocked: blocked) {
                    if best == nil || cand.count > best!.count { best = cand }
                    break
                }
            }
        }
        return best
    }

    // MARK: v5 官职/称谓词表 + 名用字正向集合

    /// 名用字（正向集合）：只有这些字可作为人名组成部分。
    /// 与 v4 的「非人名用字黑名单」思路相反——改为「白名单」约束名尾，
    /// 这样「顾琅垂眼」只会取到「顾琅」（垂不是名用字即止），不再需要穷举动词表打地鼠。
    static let givenNameChars: Set<Character> = {
        let s = "伟强刚勇军杰涛明超峰毅宇浩凯鹏斌波辉龙飞磊旭昊辰轩睿铭铠铮铁雄豪俊彦宏志国华德文建永昌盛邦振耀晨阳星海山岩松柏锋剑彪焱烁烽硕钦钧锐霖哲熙渊帅飒川" +
        "婷娟秀丽燕玲芳娜静淑惠美倩雪梅兰竹菊莲茹薇雅婉馨怡悦欣彤丹琳璐瑾萱萌蕊婧韵娇萍霞月盈依曼柔诗梦琪瑶嫣晴芸菲茜露霜仪凤姗嫒霓翩舜娥姝娆妤" +
        "安定律清秀英华国建永盛邦振耀晨阳星海山岩松柏锋剑彪哲熙渊帅书礼乐春秋冬夏东南西北金木水火土石田禾米谷鱼鸟马牛虎兔蛇猴鸡狗猪风云雷电波涛江河湖峰岭林森木草花叶根枝泉溪流原野园林城乡村路道门窗桥舟船车光明亮新旧好真善美心思想念知行言信忠孝仁义智和安乐喜福寿康宁静泰祥瑞锦绣彩虹玉珠宝珍珑珊瑚琥珀玫瑰茉莉荷蓉蕾芽苗稼穑朗乾坤银川滨朔瀚岳嵩恒岱渭洛汾淮泗沐润熙然湛澈岚霁霄汉韬略斌蔚骞翔翊骏骁昱晟旻煦昭昀晗琛璟琰璇" +
        "琅衍念放镜儿青桐封云拙墉承平山烟景行鸾凰麒麟珠玉珍宝瑜琪瑶琳萱蕊婧韵嫣菲茜露霜仪姗嫒霓翩舜娥姝娆妤七岚澈湛" +
        "哥姐弟妹娘爷伯叔舅父夫兄郎君子儿女"
        return Set(s.map { $0 })
    }()

    /// 单个字是否可作为人名组成部分（姓 / 名用字 / 阿小老昵称前缀）。
    static func isNameChar(_ c: Character) -> Bool {
        String(c).count == 1 &&
        (GenderLexicon.surnames.contains(String(c)) ||
         Self.givenNameChars.contains(c) ||
         "阿小老".contains(c))
    }

    /// 独立成词的称谓（前面不必有姓氏）：太子、御史、皇帝、公主、王爷、将军、公公、嬷嬷、大人…
    static let bareTitles: [String] = [
        "太子","皇子","阿哥","皇帝","圣上","陛下","王爷","郡王","贝勒","贝子","侯爷","国公",
        "额驸","驸马","姑爷","公主","郡主","格格","福晋","贵妃","妃","皇后","太后","才人","美人",
        "常在","答应","将军","都督","丞相","御史","尚书","侍郎","郎中","大人","翰林","知县","县令",
        "知府","刺史","节度使","太监","公公","员外","掌柜","道长","师父","方丈","和尚","仙君","壮士",
        "大侠","少侠","书生","少年","汉子","东家","老板","伙计","船夫","车夫","捕快","衙役","仵作",
        "牢头","龟公","戏子","伶人","商贾","护卫","侍卫","小厮","管家","大夫","宫女","尼姑","师太",
        "仙子","女侠","淑女","秀女","丫头","丫鬟","娘子","小姐","姑娘","夫人","妾","妻","女儿","姊",
        "妹","嫂","姑","婆","姨","婶","媳","娘","妈","妇","女王"
    ]
    /// 与姓氏组合成「姓+称谓」的称谓后缀：尚书、侍郎、将军、公子、夫人、娘、爷、大人…
    static let titleSuffixes: [String] = [
        "尚书","侍郎","郎中","御史","将军","都督","丞相","侯爷","国公","郡王","贝勒","贝子","额驸",
        "驸马","公公","太监","员外","掌柜","道长","师父","方丈","和尚","翰林","知县","县令","知府",
        "刺史","节度使","东家","姑爷","老板","伙计","船夫","车夫","捕快","衙役","仵作","牢头","龟公",
        "戏子","伶人","商贾","护卫","侍卫","小厮","管家","大夫","仙子","女侠","淑女","秀女","娘子",
        "丫鬟","丫头","嬷嬷","宫女","尼姑","师太","公子","少爷","老爷","相公","郎君","王爷","太子",
        "皇子","阿哥","爷","君","伯","叔","兄","哥","父","舅","丈","婿","郎","爹","爸","子","弟","夫",
        "男","公主","郡主","格格","福晋","贵妃","妃","皇后","太后","才人","美人","常在","答应","夫人",
        "小姐","姑娘","丫鬟","丫头","嬷嬷","宫女","尼姑","师太","仙子","女侠","淑女","秀女","娘子",
        "姐","妹","嫂","姑","婆","姨","婶","媳","女儿","姊","娘","妈","妇","妾","妻","女","女王",
        "大娘","大婶","大姐","大哥","大叔","大爷","殿下"
    ]
    /// 完整官职名（含部名，四字）：吏部尚书、礼部尚书、兵部尚书…
    static let ministryTitles: [String] = [
        "吏部尚书","礼部尚书","兵部尚书","户部尚书","刑部尚书","工部尚书",
        "吏部侍郎","礼部侍郎","兵部侍郎","户部侍郎","刑部侍郎","工部侍郎",
        "吏部郎中","礼部郎中","兵部郎中","户部郎中","刑部郎中","工部郎中"
    ]
    /// 称谓 → 性别（用于声音分配）。未列出的按后缀规则推导。
    static let titleGenderMap: [String: Gender] = {
        let male = ["太子","皇子","阿哥","皇帝","圣上","陛下","王爷","郡王","贝勒","贝子","侯爷","国公","额驸","驸马","姑爷","公子","少爷","老爷","相公","郎君","爷","君","伯","叔","兄","哥","父","舅","丈","婿","郎","爹","爸","子","弟","夫","男","将军","都督","丞相","御史","尚书","侍郎","郎中","大人","翰林","知县","县令","知府","刺史","节度使","太监","公公","员外","掌柜","道长","师父","方丈","和尚","仙君","壮士","大侠","少侠","书生","少年","汉子","东家","老板","伙计","船夫","车夫","捕快","衙役","仵作","牢头","龟公","戏子","伶人","商贾","护卫","侍卫","小厮","管家","大夫","大叔","大爷","大哥"]
        let female = ["公主","郡主","格格","福晋","贵妃","妃","皇后","太后","才人","美人","常在","答应","夫人","小姐","姑娘","丫鬟","丫头","嬷嬷","宫女","尼姑","师太","仙子","女侠","淑女","秀女","娘子","姐","妹","嫂","姑","婆","姨","婶","媳","女儿","姊","娘","妈","妇","妾","妻","女","女王","大娘","大婶","大姐"]
        var m: [String: Gender] = [:]
        for k in male { m[k] = .male }
        for k in female { m[k] = .female }
        return m
    }()

    /// 官职/称谓形态硬门槛（与 hasPersonNameShape 并列）。
    static func hasTitleShape(_ s: String, whitelist: Set<String>, blocked: Set<String>) -> Bool {
        if whitelist.contains(s) { return true }
        if blocked.contains(s) { return false }
        if Self.bareTitles.contains(s) { return true }
        if Self.ministryTitles.contains(s) { return true }
        let chars = Array(s)
        if chars.count >= 3, GenderLexicon.surnames.contains(String(chars[0])),
           Self.titleSuffixes.contains(String(chars[1...])) { return true }
        for cs in Self.compoundSurnames where s.hasPrefix(cs) {
            if Self.titleSuffixes.contains(String(s.dropFirst(cs.count))) { return true }
        }
        return false
    }

    /// 从说话动词前的字符串里挑出官职/称谓引用：太子 / 林尚书 / 吏部尚书 …。
    static func extractTitle(from raw: String, whitelist: Set<String>, blocked: Set<String>) -> String? {
        if whitelist.contains(raw) { return raw }
        // 0) 指示代词 + 称谓：「那姑娘」->「姑娘」、「那护卫」->「护卫」（避免重复建角）
        for demo in ["那", "这"] {
            if raw.hasPrefix(demo), raw.count > 2,
               let inner = extractTitle(from: String(raw.dropFirst()), whitelist: whitelist, blocked: blocked) {
                return inner
            }
        }
        // 1) 完整官职名（最长优先）
        for t in Self.ministryTitles.sorted(by: { $0.count > $1.count }) where raw.hasPrefix(t) {
            return t
        }
        // 2) 姓 + 称谓后缀
        let chars = Array(raw)
        if chars.count >= 3, GenderLexicon.surnames.contains(String(chars[0])) {
            for suf in Self.titleSuffixes.sorted(by: { $0.count > $1.count }) where raw.hasPrefix(String(chars[0]) + suf) {
                return String(chars[0]) + suf
            }
        }
        // 3) 复姓 + 称谓后缀
        for cs in Self.compoundSurnames where raw.hasPrefix(cs) {
            if Self.titleSuffixes.contains(String(raw.dropFirst(cs.count))) { return raw }
        }
        // 4) 独立称谓（前缀）
        for t in Self.bareTitles.sorted(by: { $0.count > $1.count }) where raw.hasPrefix(t) {
            return t
        }
        return nil
    }

    /// 官职/称谓 → 性别（命中具体词或后缀规则）。
    static func genderForTitle(_ s: String) -> Gender? {
        if let g = titleGenderMap[s] { return g }
        for (k, v) in titleGenderMap where k.count >= 2 && s.hasSuffix(k) {
            return v
        }
        return nil
    }

    /// 去除姓名前后称谓/敬语，得到基名。
    private let trailingTitles = ["娘子","丫鬟","少爷","老爷","夫人","王爷","相公","女侠","仙子","侠士","老爷子","公主","郡主","皇后","太后","妃","妾","妻","姊","妹","嫂","姑","婆","姨","婶","媳","女儿","姐","弟","叔","伯","舅","父","夫","兄","哥","郎","爹","爸","爷","子","婿","郎君","将军","殿下"]
    /// 描述词 → 性别（那少年 / 那女子 等）
    private let descriptorGender: [String: Gender] = [
        "那少年": .male, "那书生": .male, "那公子": .male, "那青年": .male, "那老者": .male, "这少年": .male, "那汉子": .male,
        "那女子": .female, "那丫头": .female, "这丫头": .female, "那小姐": .female, "那妇人": .female, "这女子": .female, "那姑娘": .female
    ]

    /// 捕获名尾部的修饰字/说话动词（用于剥离「林浩笑道→林浩笑」类噪声）
    static let tailNoise = "微轻低高厉冷沉急忙连便就又再一了着说道曰问答喊叫笑怒叹哭应回劝禀奏言吟呼喝骂斥吼瞪咬牙气"

    /// 虚词/功能字：候选名任一位置含这些字（或以这些字开头）即拒绝（「去我坟前」「严的」「那时」…）
    static let funcChars: Set<Character> = Set("的地得了着过是在有也就还都被把让给对向跟和与或而之其这那哪谁什么不没很太更最挺去来上下前后里外中时吧吗呢啊呀哦嘛啥我你他她它它们咱你们各位众家等每某某别莫勿未无非是于至亦即却皆要能会可肯敢该得须想越愈渐相互对独自本另彼此")
    /// 处所/器物后缀：「顾府」「相府」「茅房」「石头」等非人名
    static let placeSuffixes: Set<Character> = Set("宫府殿房院门楼阁厅堂头庄苑寺观庵")
    /// 量词/数词前缀：「一张脸」「一个人」的前一字，排除其后的姓氏扫描
    static let measurePrev: Set<Character> = Set("一两三个半几各式双条名位只匹颗座间张块")

    public init() {}

    // MARK: 主入口

    public func analyze(_ text: String, userStopwords: Set<String> = [], userWhitelist: Set<String> = []) -> AnalysisResult {
        let units = segmentText(text)
        // 内置停用词 + 用户自定义过滤名单（设置页维护；名单中的词不可能是名字）
        let blocked = Self.nameStopwords.union(userStopwords)
        // 用户白名单：一定是人名/称呼。清洗/准入/碎片检查全部豁免，且旁白中出现即注册。
        let whitelist = userWhitelist

        // ---- v3 Stage0：特征统计（只生成候选，不注册）----
        var subjectHits: [String: Int] = [:]      // 作为引号前「主语」出现的次数（正向核心特征）
        var adverbHits: [String: Int] = [:]       // 出现在状语/修饰位的次数（强负向）
        var quoteCounts: [String: Int] = [:]      // 每个角色最终拥有的台词数（Stage3 复核用）
        var sameSpeakerStreak = 0                 // 连续同一说话人的句数（对话轮次状态机）
        var previousSpeaker: String? = nil

        // ---- Pass 1：说话人候选计数（所有长度；三字及以上构成「长名」） ----
        var speakerCounts: [String: Int] = [:]
        for unit in units {
            if case .dialogue(_, let preceding) = unit {
                // 状语词只作负向特征，永不进入说话人候选
                for m in Self.modifiersIn(preceding) { adverbHits[m, default: 0] += 1 }
                if let raw = resolveSpeaker(preceding, blocked: blocked, whitelist: whitelist), raw != "他", raw != "她" {
                    speakerCounts[raw, default: 0] += 1
                    subjectHits[raw, default: 0] += 1
                }
            }
        }
        let longNames = speakerCounts.filter { $0.value >= 2 && $0.key.count >= 3 }.map(\.key)

        // ---- 旁白二字候选扫描（长名占位排除后） ----
        func scanNarration(_ body: String) -> [String] {
            var cleaned = body
            if let re = try? NSRegularExpression(pattern: "第[一二三四五六七八九十百千0-9]+[章回卷]") {
                cleaned = re.stringByReplacingMatches(
                    in: body,
                    range: NSRange(location: 0, length: (body as NSString).length),
                    withTemplate: "")
            }
            let chars = Array(cleaned)
            guard chars.count >= 2 else { return [] }
            var masked = [Bool](repeating: false, count: chars.count)
            for l in longNames {
                let lchars = Array(l)
                guard lchars.count <= chars.count else { continue }
                for p in 0...(chars.count - lchars.count) {
                    if Array(chars[p..<(p + lchars.count)]) == lchars {
                        for k in p..<(p + lchars.count) { masked[k] = true }
                    }
                }
            }
            var out: [String] = []
            var i = 0
            while i < chars.count - 1 {
                if Self.isLikelySurname(chars[i]), !masked[i], !masked[i + 1] {
                    let three = String(chars[i...min(i + 2, chars.count - 1)])
                    if descriptorGender.keys.contains(three) {
                        i += 3
                        continue
                    }
                    let second = chars[i + 1]
                    let cand = String([chars[i], second])
                    let prevOk = (i == 0) || !Self.measurePrev.contains(chars[i - 1])
                    if Self.isHan(second), chars[i] != second, prevOk,
                       !blocked.contains(cand), !out.contains(cand) {
                        out.append(cand)
                    }
                }
                i += 1
            }
            return out
        }

        var narrationCounts: [String: Int] = [:]
        for unit in units {
            if case .narration(let t) = unit {
                for cand in scanNarration(t) {
                    if let c = cleanCandidate(cand, blocked: blocked, whitelist: whitelist), c != "他", c != "她" {
                        narrationCounts[c, default: 0] += 1
                    }
                }
                // 白名单词出现即计数（不依赖姓氏扫描，如「大爷」「老王」等称谓）
                for w in whitelist where t.contains(w) {
                    narrationCounts[w, default: 0] += 1
                }
            }
        }
        var totalCounts: [String: Int] = [:]
        for k in Set(narrationCounts.keys).union(speakerCounts.keys) {
            totalCounts[k] = (narrationCounts[k] ?? 0) + (speakerCounts[k] ?? 0)
        }
        func admitted(_ c: String?) -> Bool {
            guard let c, c != "他", c != "她" else { return false }
            // 白名单词一定是人名，直接准入（用户自定义人名保持最高优先级）
            if whitelist.contains(c) { return true }
            // 黑名单 / 非人名词典：硬过滤（用户自定义过滤词同样在此生效）
            if blocked.contains(c) { return false }
            // v5：官职/称谓形态 或 人名形态，二选一即可越过硬门槛
            let isTitle = Self.hasTitleShape(c, whitelist: whitelist, blocked: blocked)
            let isName = Self.hasPersonNameShape(c, whitelist: whitelist, blocked: blocked)
            guard isName || isTitle else { return false }
            // v3：只在状语位出现、从未作过主语 → 描写词，一票否决
            if (adverbHits[c] ?? 0) > 0, (subjectHits[c] ?? 0) == 0 { return false }
            let subs = subjectHits[c] ?? 0
            if isTitle {
                // 官职/称谓：至少一次作台词主语（太子/御史/礼部尚书 等低频也要能解析）
                return subs >= 1
            }
            switch c.count {
            case 2:
                // 二字名核心正向信号：至少一次作为台词主语（真实人名必说话；羊腿/马肉 纯旁白且
                // hasPersonNameShape 的形态门槛已排除它们，无需抬到 >=2）。恢复 v4 同源规则，
                // 保证只作一次主语的真实两字名（林浩/苏婷/顾琅）也能被识别，连带代词/别名合并正常。
                return subs >= 1 || ((narrationCounts[c] ?? 0) + (speakerCounts[c] ?? 0) >= 2 && (adverbHits[c] ?? 0) == 0)
            case 3:
                // 三字名：若其前二字本身就是一个高频人名（如「阮念谢」是「阮念」+「谢(动词/姓)」），
                // 则判为「真名+状语尾字」碎片予以剔除；真三字名（慕容衍/屈封云…）前缀远不如全名高频，保留。
                let p2 = String(c.prefix(2))
                if (Self.hasPersonNameShape(p2, whitelist: whitelist, blocked: blocked) || subjectHits[p2] != nil),
                   (totalCounts[p2] ?? 0) >= max(2, (totalCounts[c] ?? 0) * 2) {
                    return false
                }
                return subs >= 1 || (speakerCounts[c] ?? 0) >= 2
            default:
                return false
            }
        }
        func isFragment(_ c: String) -> Bool {
            if whitelist.contains(c) { return false }
            if Self.hasTitleShape(c, whitelist: whitelist, blocked: blocked) { return false }
            for l in longNames where l.count > c.count && l.contains(c) {
                if (totalCounts[c] ?? 0) < (totalCounts[l] ?? 0) { return true }
            }
            return false
        }

        // ---- Pass 2：构建角色与分段 ----
        var roles: [CharacterRole] = []
        var aliasToRole: [String: String] = [:]
        var sceneRecent: [String] = []   // 当前场景内最近出现过的角色 id（用于代词/描述词回指）
        var lastDialogueSpeaker: String? = nil   // 上一句台词的说话人（「他说」优先指他）
        var segments: [SpeechSegment] = []
        var segIndex = 0

        func roleGender(_ id: String) -> Gender? {
            roles.first(where: { $0.id == id })?.gender
        }
        func indexOfRole(_ id: String) -> Int? {
            roles.firstIndex(where: { $0.id == id })
        }
        func ensureSceneRecent(_ id: String) {
            sceneRecent.removeAll(where: { $0 == id })
            sceneRecent.append(id)
            if sceneRecent.count > 10 { sceneRecent.removeFirst() }
        }
        func addAlias(_ raw: String, to id: String) {
            aliasToRole[raw] = id
            if let idx = indexOfRole(id), !roles[idx].aliases.contains(raw) {
                roles[idx].aliases.append(raw)
            }
        }
        func hintFor(_ g: Gender) -> String? {
            switch g { case .male: return "male"; case .female: return "female"; case .neutral: return "neutral" }
        }
        /// 解析别名：X兄/老X/X公/X爷 → 基名匹配已有角色
        func resolveAlias(_ raw: String) -> String? {
            if let id = aliasToRole[raw] { return id }
            var base = raw
            while base.hasPrefix("老") || base.hasPrefix("小") { base.removeFirst() }
            var changed = true
            while changed {
                changed = false
                for t in trailingTitles where base.hasSuffix(t) && base.count > t.count {
                    base.removeLast(t.count); changed = true; break
                }
            }
            if base.isEmpty { return nil }
            for role in roles {
                if role.canonicalName.hasPrefix(base) || role.aliases.contains(where: { $0.hasPrefix(base) }) {
                    return role.id
                }
            }
            return nil
        }
        /// 注册或合并一个说话人表面形式，返回其 roleId
        func registerOrMerge(surface: String) -> String {
            let key = surface
            if let id = aliasToRole[key] { return id }
            if let id = resolveAlias(surface) { addAlias(surface, to: id); return id }
            let g = genderFor(surface)
            let id = "role_\(roles.count)"
            let role = CharacterRole(id: id, canonicalName: surface, aliases: [surface], gender: g, voiceHint: hintFor(g))
            roles.append(role)
            aliasToRole[surface] = id
            return id
        }
        /// 解析代词（他/她）到最近同性别角色。
        /// 「……。"他说，"」紧跟引语的「他」优先指上一个说话的人（同一人物）。
        func resolvePronoun(_ p: String) -> String? {
            let want: Gender? = (p == "她") ? .female : .male
            if let last = lastDialogueSpeaker {
                if let g = roleGender(last) {
                    if want == nil || g == want {
                        // v3 Stage2：连续 3 句都是同一人时，按 A-B-A-B 轮次交替先验改指另一位活跃角色
                        if sameSpeakerStreak >= 3,
                           let alt = sceneRecent.last(where: { $0 != last && (want == nil || roleGender($0) == want) }) {
                            return alt
                        }
                        return last
                    }
                } else {
                    return last
                }
            }
            if p == "她" {
                return sceneRecent.last(where: { roleGender($0) == .female })
            } else {
                return sceneRecent.last(where: { roleGender($0) == .male }) ?? sceneRecent.last
            }
        }
        /// 说话人兜底：在引语前的短窗口内找已知角色名/别名、描述词或代词。
        /// 两级优先：先看**角色正式名称**（canonical）中最后出现者——动作句（「慕容衍一边躲一边继续鬼扯，"…」）
        /// 的说话人是句首的动作主体，不能被句中后出现的杂词/别名（如「鬼扯」）抢走；找不到再退到别名/描述词/代词。
        func fallbackSpeaker(in preceding: String) -> String? {
            let tail = String(preceding.suffix(min(preceding.count, 24)))
            var best: (pos: Int, len: Int, name: String)? = nil
            func consider(_ name: String) {
                guard !name.isEmpty, let r = tail.range(of: name, options: .backwards) else { return }
                let pos = tail.distance(from: tail.startIndex, to: r.lowerBound)
                if best == nil || pos > best!.pos || (pos == best!.pos && name.count > best!.len) {
                    best = (pos, name.count, name)
                }
            }
            // 第一优先：角色正式名称
            for role in roles { consider(role.canonicalName) }
            if let b = best { return b.name }
            // 第二优先：别名 / 描述词 / 代词
            for role in roles {
                for a in role.aliases { consider(a) }
            }
            for k in descriptorGender.keys { consider(k) }
            consider("她")
            consider("他")
            return best?.name
        }

        for unit in units {
            switch unit {
            case .narration(let t):
                if isChapterMarker(t) { sceneRecent.removeAll() }
                for cand in scanNarration(t) {
                    let c = cleanCandidate(cand, blocked: blocked, whitelist: whitelist)
                    guard let name = c, name != "他", name != "她", admitted(name), !isFragment(name) else { continue }
                    let id = registerOrMerge(surface: name)
                    ensureSceneRecent(id)
                }
                // 白名单词在旁白中出现即注册（不依赖姓氏扫描）
                for w in whitelist where t.contains(w) {
                    let id = registerOrMerge(surface: w)
                    ensureSceneRecent(id)
                }
                segments.append(SpeechSegment(id: "seg_\(segIndex)", text: t, characterId: nil, emotion: .neutral, position: segIndex))
                segIndex += 1

            case .dialogue(let quote, let preceding):
                let emotion = EmotionLexicon.detect(before: preceding, quote: quote)
                var speakerId: String? = nil
                var raw = resolveSpeaker(preceding, blocked: blocked, whitelist: whitelist)
                if raw == nil {
                    raw = fallbackSpeaker(in: preceding)
                }
                if let raw {
                    if raw == "他" || raw == "她" {
                        if let id = resolvePronoun(raw) {
                            addAlias(raw, to: id)
                            speakerId = id
                        }
                    } else if let g = descriptorGender[raw] {
                        if let id = sceneRecent.last(where: { roleGender($0) == g }) {
                            addAlias(raw, to: id)
                            speakerId = id
                        } else {
                            speakerId = registerOrMerge(surface: raw)
                        }
                    } else if let id = resolveAlias(raw) {
                        // 已有角色的别名（X兄/老X/称谓变体）：直接并入，不走准入门槛
                        addAlias(raw, to: id)
                        speakerId = id
                    } else if admitted(raw), !isFragment(raw) {
                        // 全新表面形式：必须通过频次准入，避免一次性垃圾注册成角色
                        speakerId = registerOrMerge(surface: raw)
                    }
                }
                if let id = speakerId {
                    ensureSceneRecent(id)
                    lastDialogueSpeaker = id
                    // v3：为 Stage3 复核与轮次状态机留证据
                    quoteCounts[id, default: 0] += 1
                    if id == previousSpeaker { sameSpeakerStreak += 1 } else { sameSpeakerStreak = 1 }
                    previousSpeaker = id
                }
                segments.append(SpeechSegment(id: "seg_\(segIndex)", text: quote, characterId: speakerId, emotion: emotion, position: segIndex))
                segIndex += 1
            }
        }

        // ---- 后处理：canonical = 别名中出现频次最高者（长名优先打破平局） ----
        for i in roles.indices {
            let cands = [roles[i].canonicalName] + roles[i].aliases
            let best = cands.max { a, b in
                let ca = totalCounts[a] ?? 0, cb = totalCounts[b] ?? 0
                if ca != cb { return ca < cb }
                return a.count < b.count
            }
            if let best { roles[i].canonicalName = best }
        }

        // ---- v3 Stage3：全局复核（可回滚）----
        // 旧算法「边扫边注册、单向不可逆」；这里在全书解析完成后统一淘汰：
        //  ① 命中非人名词典 / 用户黑名单  ② 既没作过主语、也没拥有过台词
        // 白名单词全豁免，用户自定义人名永远保留。
        var removedIds = Set<String>()
        for role in roles {
            if whitelist.contains(role.canonicalName) { continue }
            let names = Set([role.canonicalName] + role.aliases)
            if names.contains(where: { blocked.contains($0) || Self.speechModifiers.contains($0) }) {
                removedIds.insert(role.id)
                continue
            }
            let quotes = quoteCounts[role.id] ?? 0
            let subjects = names.reduce(0) { $0 + (subjectHits[$1] ?? 0) }
            if quotes == 0 && subjects == 0 { removedIds.insert(role.id) }
        }
        if !removedIds.isEmpty {
            roles.removeAll { removedIds.contains($0.id) }
            for i in segments.indices where segments[i].characterId.map({ removedIds.contains($0) }) == true {
                segments[i].characterId = nil
            }
        }

        // ---- 后处理：段落停顿。旁白/台词分段可能跨多个自然段（segmentText 的缓冲区跨行累积），
        // 不拆开就出现「作者：长烟」直接连读「诈死后」的情况。按行拆为独立分段，
        // 非末行行尾追加段落停顿标记（TextChunker.paragraphBreakMarker），朗读器据此插入停顿。
        var finalSegments: [SpeechSegment] = []
        var pos = 0
        for seg in segments {
            let lines = seg.text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if lines.count <= 1 {
                finalSegments.append(SpeechSegment(id: "seg_\(pos)", text: seg.text,
                                                   characterId: seg.characterId, emotion: seg.emotion, position: pos))
                pos += 1
            } else {
                for (li, line) in lines.enumerated() {
                    var lineText = line
                    if li < lines.count - 1 { lineText += TextChunker.paragraphBreakMarker }
                    finalSegments.append(SpeechSegment(id: "seg_\(pos)", text: lineText,
                                                       characterId: seg.characterId, emotion: seg.emotion, position: pos))
                    pos += 1
                }
            }
        }

        return AnalysisResult(roles: roles, segments: finalSegments)
    }

    // MARK: 文本切分

    private enum Unit {
        case narration(String)
        case dialogue(quote: String, preceding: String)
    }

    /// 将文本切分为旁白段与对话段（对话带其前的叙述文本，用于定位说话人）。
    private func segmentText(_ text: String) -> [Unit] {
        let open: [Character: Character] = ["「": "」", "“": "”", "‘": "’", "『": "』"]
        var units: [Unit] = []
        var buffer = ""
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if let close = open[c] {
                let preceding = buffer
                if !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    units.append(.narration(buffer))
                }
                buffer = ""
                var j = text.index(after: i)
                var quote = ""
                while j < text.endIndex {
                    if text[j] == close { break }
                    quote.append(text[j])
                    j = text.index(after: j)
                }
                units.append(.dialogue(quote: quote, preceding: preceding))
                i = text.index(after: j)
            } else {
                buffer.append(c)
                i = text.index(after: i)
            }
        }
        if !buffer.isEmpty { units.append(.narration(buffer)) }
        return units
    }

    // MARK: 候选清洗与说话人解析

    static func isHan(_ c: Character) -> Bool {
        c.unicodeScalars.first.map {
            (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value)
        } == true
    }
    static func isLikelySurname(_ char: Character) -> Bool {
        GenderLexicon.surnames.contains(String(char))
    }

    /// 候选清洗：剥尾部说话动词噪声 → 剥头部虚词 → 长度 2–3 → 不含虚词 → 非处所后缀 → 不在停用词表。
    /// blocked = 内置停用词 + 用户自定义过滤名单；whitelist 命中则原样放行（用户确认为人名/称呼）。
    private func cleanCandidate(_ raw: String?, blocked: Set<String>, whitelist: Set<String> = []) -> String? {
        guard var r = raw, !r.isEmpty else { return nil }
        if r == "他" || r == "她" { return r }
        if whitelist.contains(r) { return r }
        while let last = r.last, Self.tailNoise.contains(last) { r.removeLast() }
        while let first = r.first, Self.funcChars.contains(first) { r.removeFirst() }
        guard r.count >= 2, r.count <= 3 else { return nil }
        if r.contains(where: { Self.funcChars.contains($0) }) { return nil }
        if let last = r.last, Self.placeSuffixes.contains(last) { return nil }
        if blocked.contains(r) { return nil }
        return r
    }

    /// v4 说话人解析：
    /// ① 只看引号前最后一个分句（旁白中间的「满口胡言乱语」「反倒笑了笑」不再被当作引语提示）；
    /// ② 说话动词必须落在该分句末尾；
    /// ③ 捕获串剥掉状语修饰后，必须能提取出「人名形态证据」的子串，否则返回 nil。
    private func resolveSpeaker(_ preceding: String, blocked: Set<String>, whitelist: Set<String> = []) -> String? {
        let window = String(preceding.suffix(min(preceding.count, 24)))
        let seps = CharacterSet(charactersIn: "。！？!?；;\n，,：:、")
        let parts = window.components(separatedBy: seps)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let clause = (parts.last ?? window).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clause.isEmpty else { return nil }
        let pattern = "([\\u4e00-\\u9fa5]{1,10})([地得了]?)(?:\(Self.strictSpeechVerbs))$"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = clause as NSString
        guard let m = re.firstMatch(in: clause, range: NSRange(location: 0, length: ns.length)) else { return nil }
        guard m.range(at: 2).length == 0 else { return nil }   // 「X地说」等副词修饰跳过
        let start = m.range(at: 1).location
        if start > 0, Self.measurePrev.contains(Character(ns.substring(with: NSRange(location: start - 1, length: 1)))) {
            return nil
        }
        var raw = ns.substring(with: m.range(at: 1))
        if whitelist.contains(raw) { return raw }
        // v5：先尝试官职/称谓（太子 / 林尚书 / 吏部尚书 …），命中即返回
        if let t = Self.extractTitle(from: raw, whitelist: whitelist, blocked: blocked) { return t }
        let mods = Self.speechModifiers.sorted { $0.count > $1.count }
        var changed = true
        while changed, !raw.isEmpty {
            changed = false
            if let l = raw.last, Self.funcChars.contains(l) || Self.tailNoise.contains(l) {
                raw.removeLast(); changed = true; continue
            }
            for mod in mods where raw.hasSuffix(mod) && raw.count >= mod.count {
                raw = String(raw.dropLast(mod.count)); changed = true; break
            }
        }
        if raw == "他" || raw == "她" { return raw }
        if let t = Self.extractTitle(from: raw, whitelist: whitelist, blocked: blocked) { return t }
        return Self.extractPersonName(from: raw, whitelist: whitelist, blocked: blocked)
    }
    /// 扫描误报黑名单（姓氏+常用词组合、常见双字词等；数据驱动，持续补充；另支持用户自定义名单）
    static let nameStopwords: Set<String> = [
        "英雄", "神情", "突然", "但是", "可是", "然后", "已经", "因为", "所以", "现在",
        "这时", "自己", "他们", "她们", "我们", "你们", "什么", "怎么", "大家", "众人",
        "一声", "微微", "缓缓", "默默", "渐渐", "轻轻", "慢慢", "郁郁", "悠悠",
        "匆匆", "立刻", "马上", "于是", "只是", "就是", "还是", "也是", "又是",
        "很快", "胡扯",
        "安静", "沙雕", "便宜", "高兴", "生气", "明白", "知道", "时候", "地方", "东西",
        "事情", "问题", "关系", "开始", "最后", "终于", "居然", "竟然", "忽然", "依然",
        "仍然", "当然", "显然", "果然", "原来", "其实", "曾经", "后来", "不过", "因此",
        "虽然", "然而", "一会", "一时", "半天", "起来", "出来", "上来", "下来", "回来",
        "说道", "的话", "方才", "万分", "许久", "冷漠", "冷静", "认真", "仔细", "耐心",
        "使劲", "用力", "猛地", "顿时", "瞬间", "立时", "登时", "随即", "接着", "半晌",
        "良久", "片刻", "一愣", "一怔", "一笑", "点头", "摇头", "抬头", "低头", "转身",
        "起身", "咬唇", "皱眉", "挑眉", "睁眼", "闭眼", "出声", "开口", "接口", "应声",
        "轻笑", "低笑", "苦笑", "嘴角", "眼底", "眼神", "目光", "声音", "语气", "平静",
        "淡淡", "笑意", "笑容", "眼泪", "泪水", "哭声", "沉默", "沉声", "冷声", "淡声",
        "低语", "呢喃", "心中", "心里", "心底", "脸上", "面上", "身子", "身体", "怀里",
        "怀中", "手中", "手里", "眼前", "关切", "沙哑", "明珠", "黄泉", "严关", "严忧",
        "喃喃", "一人", "许多", "两人", "三人", "众人", "安慰", "解释", "房间", "房内",
        "小声", "随口", "水花", "养起", "湛重", "明所", "明晃", "严拍", "皮面", "云见",
        "云眼", "云看", "云扛", "云听", "严重", "周身", "马场", "包子", "姜水", "祁往",
        "安宁", "红色", "红血", "明知", "权倾", "马步", "石壁", "石阶", "林间", "好意",
        "好意思", "乐意", "费力", "包扎", "马车", "马鞭", "高挂",
        // v3：把「打地鼠黑名单」升级为系统化非人名词典（动作 / 情绪 / 状语）
        "脱口", "抬眼", "心疼", "轻声", "低声", "高声", "厉声", "柔声", "急声", "连声",
        "抬眸", "垂眸", "抬手", "抿唇", "轻叹", "低沉", "轻笑", "低笑", "苦笑", "冷笑",
        "关切", "沙哑", "平静", "淡淡", "呢喃", "喃喃", "低语", "沉吟", "猛地", "顿时",
        "瞬间", "忽然", "突然", "匆匆", "微微", "缓缓", "默默", "渐渐", "轻轻", "慢慢",
        "点头", "摇头", "开口", "出声", "接口", "应声", "转身", "起身", "皱眉", "挑眉",
        "咬唇", "沉声", "冷声", "淡声", "小声", "大声", "心中", "心底", "眼底", "笑意"
    ]

    /// 去姓名前后称谓/敬语，得到基名（林风兄→林风，老林→林）。
    private func normalizeName(_ s: String) -> String {
        var r = s
        while r.hasPrefix("老") || r.hasPrefix("小") { r.removeFirst() }
        var changed = true
        while changed {
            changed = false
            for t in trailingTitles where r.hasSuffix(t) && r.count > t.count {
                r.removeLast(t.count); changed = true; break
            }
        }
        return r
    }

    /// 章节标记（重置场景上下文）：第X章/回/卷。
    private func isChapterMarker(_ t: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: "第[一二三四五六七八九十百千0-9]+[章回卷]") else { return false }
        return re.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)) != nil
    }

    // MARK: 性别（多角度投票）

    /// 综合判定一个表面形式的性别：称谓 + 关系词 + 名字用字 + 代词。
        private func genderFor(_ surface: String) -> Gender {
            var score = GenderScore()
            if let g = Self.genderForTitle(surface) { score.add(g, weight: 3) }
            if let g = GenderLexicon.titleGender(surface) { score.add(g, weight: 2) }
            if let g = GenderLexicon.relationGender(surface) { score.add(g, weight: 2) }
            let nameScore = GenderLexicon.score(for: surface)
            score.male += nameScore.male
            score.female += nameScore.female
            if surface == "她" { score.add(.female, weight: 1) }
            if surface == "他" { score.add(.male, weight: 1) }
            return score.result(threshold: 0)
        }
}
