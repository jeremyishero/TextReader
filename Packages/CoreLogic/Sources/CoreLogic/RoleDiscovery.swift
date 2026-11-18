import Foundation

// MARK: - jieba 风格角色发现（对齐 PC 端 analyze_roles_jieba.py）
//
// 设计：iOS 无 jieba，本文件用纯 Swift 复刻 PC 算法的数据驱动内核：
//   1) 引号对话切分，抽「冒号前 / 引号后」说话位置短语；
//   2) 用「形态规则 + 通用词表」替代 jieba 词性，从说话位置抽角色候选
//      （独立姓名 / 姓+身份 / 绰号 / 复姓+名 / nr姓+2字名）；
//   3) 全书 2~4 字汉字滑窗词频 + 说话位置绑定数 + 紧贴边界共现，三路信号打分；
//   4) 前缀碎片过滤 + 同姓身份称谓别名合并（显著领先判据）；
//   5) 精确归属：候选命中主角色即说话人，泛称绑定年长角色，其余旁白。
// 对外只暴露 `JiebaStyleAnalyzer.analyze(_:)`，返回 AnalysisResult，接口与旧引擎一致。

public struct JiebaStyleAnalyzer {

    public init() {}

    // ---------- 通用词表（与 PC 端一致，均为通用规则而非人名特例）----------
    private static let speechVerbs: Set<String> = Set("""
    说 道 曰 问 答 喊 叫 笑 叹 哭 应 回 劝 禀 奏 言 吟 呼 唤 喝 骂 斥 吼 叱 嘀咕 嘟囔 念叨 咕哝
    嚷 吩咐 补充 低声 喃喃 怒斥 冷哼 说道 喊道 问道 答道 大怒 大喜 一凝 一愣 闻言 点头 摇头
    皱眉 微微 缓缓 忽然 站起 坐下 望着 看向 止住 咳嗽 说出 开口 沉默 思索 又道 接着 转向 走到
    指着 递给 道 说 喊 叫 问 答 叹 喝 笑
    """.split())

    private static let postVerbs: [String] = {
        let s = "说道 喊道 叫道 答道 叹道 低声道 喃喃道 怒斥道 喝道 笑道 笑骂 说 道 喊 叫 问 答 叹 低声 喃喃 怒斥 喝 笑"
        return s.split(separator: " ").map(String.init).sorted { $0.count > $1.count }
    }()

    private static let generic: Set<String> = Set("""
    老者 此人 那人 对方 少年 少女 妇人 汉子 中年 青年 女子 男子 小孩 孩子 众人 大家 有人 旁人 来人
    师兄 师弟 师姐 师妹 公子 少爷 老爷 夫人 姑娘 仙子 道友 长老 护法 堂主 门主 宗主 掌柜 先生 大人
    老汉 丫头 童子 冷笑 冷哼 大笑 微笑 沉默 老祖 明尊 圣祖 真君 上人 黑甲 白发 胡子 灰衣 青衣
    白衣 黑袍 童颜 鹤发 金发 红衣 中年人 老年人 年轻人 儒生 书生 美妇 少妇 老妇 白袍 灰袍 青袍
    黑衣 魔族 妖族 人族 修士 凡人 武者 高手 壮汉 大汉 修仙 修真 阴晴不定 言语 话语 巨猿 妖兽
    灵兽 冰凤 银翅 老妪 老道 老妇人 老翁 大头 紫发 徐姓 某姓 小人 方一 白光 闻听 千秋 白眉
    金光 金焰 老二 翁姓 黄发 宋姓 徐徐 施一礼 灵石 红光 青光 韩兄 小老头 许老怪
    """.split())

    // 身份后缀：可与姓组成称呼（岳堂主/墨大夫/厉师兄）
    private static let personTitles: Set<String> = Set("""
    堂主 护法 大夫 长老 门主 宗主 掌门 教习 管家 伙计 少爷 公子 先生 大人 老者 少年 少女 姑娘
    夫人 娘子 仙子 道友 师兄 师弟 师姐 师妹 老 爷 公 伯 叔 哥 姐 弟 妹 婆 娘 父 兄 嫂 王 将 相 侯
    """.split())

    // 身体/感知名词：不拼进人名（挡「韩立目光」）
    private static let bodyNouns: Set<String> = Set("""
    目光 神色 声音 脸色 表情 语气 眼神 身影 举止 言语 话语 心头 心中 脑中 大笑 冷笑 微笑 沉默
    点头 摇头 皱眉 口气 脚步 手掌 肩膀 身躯
    """.split())

    private static let compoundSurnames: Set<String> = Set("""
    欧阳 太史 端木 上官 司马 东方 独孤 南宫 万俟 闻人 夏侯 诸葛 尉迟 皇甫 宗政 濮阳 公冶 太叔
    申屠 公孙 慕容 仲孙 轩辕 令狐 宇文 长孙 司徒 司空 澹台 公羊 赫连
    """.split())

    // 泛称指代：不作为正式角色，但绑定说话人
    private static let refWords: Set<String> = Set("这名老者 那老者 老者 此人 那人 对方".split())

    /// 解析专用姓表 = GenderLexicon.surnames ∪ PC 端姓表补集。
    /// 两表互补：GenderLexicon 有「岳」无「墨」，PC 表有「墨」无「岳」；
    /// 合并后墨大夫/岳堂主/厉飞雨/刘靖等都能识别，且不污染性别判断（只用于候选发现）。
    private static let discoverySurnames: Set<String> = {
        var s = GenderLexicon.surnames
        for c in "仇仲伊侯全冉刘厉墨宁宓宫戎景暴束栾武班甘祖秋符羽蓬詹车邴郗钭阎风龙" {
            s.insert(String(c))
        }
        return s
    }()

    // 别名身份后缀（厉师兄→厉飞雨）
    private static let aliasTitles: [String] = [
        "师兄","师弟","师姐","师妹","师叔","师伯","师姑","师侄","堂主","护法","长老","门主","宗主",
        "大夫","掌柜","管家","少爷","公子","先生","大人","老","公","伯","叔","哥","姐","弟","妹","爷"
    ].sorted { $0.count > $1.count }

    private static let blackRoots: Set<String> = Set("""
    宗 门 谷 山 殿 城 府 阁 楼 院 观 寺 诀 术 剑 丹 符 鼎 铃 旗 镜 钟 天地 江湖 黄昏 清晨
    深夜 此时 此刻 东方 西方 南方 北方
    """.split())

    // 虚词/动词字：候选片段含这些字 → 不是名词性称呼
    private static let funcChars: Set<Character> = Set("""
    的地得了着过是在有也就还都被把让给对向跟与或而之其这那哪谁什么不没很太更最又再才只已将
    从于为以并且但则若如虽即而何况乎哉矣焉耳说道问答喊叫笑叹哭应回劝禀奏言吟呼唤喝骂斥吼叱
    嘀咕嘟囔念叨咕哝嚷吩咐补充
    """)

    // 女性/男性名字特征字（与 PC 端 gender_of 一致）
    private static let femaleChars: Set<Character> = Set("婷娟秀丽燕玲芳娜静淑惠美倩雪梅兰竹菊莲茹薇雅婉馨怡悦欣彤丹琳璐瑾萱萌蕊婧韵娇萍霞月盈依曼柔诗梦琪瑶嫣晴芸菲茜露霜娘婆母姐妹姑姨嫂妃")
    private static let maleChars: Set<Character> = Set("伟强刚勇军杰涛峰毅宇浩凯鹏斌波辉龙飞磊旭昊辰轩睿铭铠铮铁雄豪俊彦国华德建永昌盛邦振耀阳海山岩松柏锋剑彪郎伯叔父兄舅爷公")

    // ---------- 对话切分 ----------
    private struct Dialogue {
        var pre: String
        var post: String
        var text: String
    }

    private static func isHan(_ c: Character) -> Bool {
        guard let s = c.unicodeScalars.first?.value else { return false }
        return s >= 0x4e00 && s <= 0x9fff
    }
    private static func isHanString(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy(isHan)
    }

    /// 引号归一：所有常见引号统一成 “ ”，交替配对
    private static func preprocess(_ raw: String) -> String {
        let noCR = raw.replacingOccurrences(of: "\r", with: "")
        var out = ""
        var open = true
        for ch in noCR {
            if ch == "\"" || ch == "「" || ch == "『" {
                out.append(open ? "“" : "”"); open.toggle()
            } else if ch == "」" || ch == "』" {
                out.append("”"); open = true
            } else {
                out.append(ch)
            }
        }
        return out
    }

    private static func cleanLines(_ text: String) -> [String] {
        var out: [String] = []
        for raw in text.split(separator: "\n") {
            let s = raw.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\u{3000}", with: " ")
            if s.isEmpty || s.contains("本书由") || s.contains("www.") || s.contains("版权归作者") || s.contains("收集整理") { continue }
            out.append(s)
        }
        return out
    }

    /// 只认 “…” 包裹；嵌套引号属台词内部。抽前置(句末标点前)/后置(逗号前)。
    private static func extractDialogues(_ full: String) -> [Dialogue] {
        let chars = Array(full)
        var res: [Dialogue] = []
        var i = 0
        let n = chars.count
        while i < n {
            if chars[i] != "“" { i += 1; continue }
            let start = i + 1
            var depth = 1
            var j = start
            while j < n {
                if chars[j] == "“" { depth += 1 }
                else if chars[j] == "”" {
                    depth -= 1
                    if depth == 0 { break }
                }
                j += 1
            }
            if j >= n { break }
            let qtext = String(chars[start..<j])
            let qend = j + 1
            // 前置：向前找句末标点
            var ps = i - 1
            let stoppers: Set<Character> = ["。","！","？","!","?","；",";"]
            while ps >= 0 && !stoppers.contains(chars[ps]) { ps -= 1 }
            let pre = String(chars[(ps + 1)..<i]).trimmingCharacters(in: .whitespaces)
            // 后置：向后找句末/逗号（≤20字）
            var pe = qend
            let postStop: Set<Character> = ["。","！","？","!","?","；",";","，",","]
            let limit = min(n, qend + 20)
            while pe < limit && !postStop.contains(chars[pe]) { pe += 1 }
            let post = String(chars[qend..<pe]).trimmingCharacters(in: .whitespaces)
            res.append(Dialogue(pre: pre, post: post, text: qtext))
            i = qend
        }
        return res
    }

    // MARK: - stage 1: 说话位置候选（形态规则替代 jieba 词性）

    /// 把片段切成「词」：这里不做真分词，而是从每个位置尝试抽名词性候选（2~4字）。
    /// 返回 [(位置, 候选)]，候选已过形态门槛。
    private static func nameCandidates(in frag: String) -> [(Int, String)] {
        let chars = Array(frag)
        var hits: [(Int, String)] = []
        // 在言说动词处截断
        var cut = chars.count
        for i in 0..<chars.count {
            let two = i + 1 < chars.count ? String(chars[i...i+1]) : ""
            let one = String(chars[i])
            if speechVerbs.contains(two) || speechVerbs.contains(one) { cut = i; break }
        }
        let active = Array(chars[0..<cut])
        guard !active.isEmpty else { return [] }

        for i in 0..<active.count {
            // a) 独立姓名：从位置 i 起取 2~4 字，满足「姓开头」或「复姓」或「绰号构词」
            for L in [4, 3, 2] {
                guard i + L <= active.count else { continue }
                let tok = String(active[i..<(i+L)])
                guard isHanString(tok), isNameLike(tok, atSegmentStart: i == 0) else { continue }
                hits.append((i, tok))
                break   // 同位置取最长
            }
            // b) 姓(1字) + 身份/名 = 复合称呼（岳堂主/墨大夫/厉飞雨）
            if i + 1 < active.count, discoverySurnames.contains(String(active[i])) {
                let next1 = String(active[i+1])
                if personTitles.contains(next1) {
                    hits.append((i, String(active[i...i+1])))
                } else if i + 2 < active.count {
                    let next2 = String(active[i+1...i+2])
                    if isHanString(next2), !bodyNouns.contains(next2), isNameTail(next2) {
                        hits.append((i, String(active[i...i+2])))
                    }
                }
            }
            // c) 复姓 + 1字（南宫婉）
            if i + 2 < active.count {
                let two = String(active[i...i+1])
                if compoundSurnames.contains(two), isHan(active[i+2]) {
                    hits.append((i, String(active[i...i+2])))
                }
            }
        }
        // 去重叠：同位置保留最长
        var out: [(Int, String)] = []
        for h in hits.sorted(by: { $0.0 < $1.0 || ($0.0 == $1.0 && $0.1.count > $1.1.count) }) {
            if out.contains(where: { $0.0 <= h.0 && h.0 < $0.0 + $0.1.count }) { continue }
            out.append(h)
        }
        return out
    }

    /// 候选是否「像人名/名词」——替代 jieba 的 nr/n 词性判断
    private static func isNameLike(_ tok: String, atSegmentStart: Bool) -> Bool {
        guard tok.count >= 2, tok.count <= 4, isHanString(tok) else { return false }
        if generic.contains(tok) { return false }
        if tok.contains(where: { funcChars.contains($0) }) { return false }
        if blackRoots.contains(where: { tok.contains($0) }) { return false }
        if objectTails.contains(where: { tok.contains($0) }) { return false }
        let chars = Array(tok)
        // 独立姓名：姓 或 复姓 开头
        if discoverySurnames.contains(String(chars[0])) {
            if tok.count <= 3 { return true }
        }
        for cs in compoundSurnames where tok.hasPrefix(cs) {
            return tok.count <= cs.count + 2
        }
        // 绰号：段首「小/老/大/阿 + 1~3字」，尾字非名用字（小算盘）
        if atSegmentStart, tok.count == 3, "小老大阿".contains(chars[0]) {
            return true
        }
        return false
    }

    /// 名尾字：可接在单字姓后构成姓名（飞雨/天龙）。
    /// 必须排除物品/功法/术语词根（丹/丸/根/步/诀…）与身体名词，
    /// 否则「黄龙丹/金髓丸/水灵根/罗烟步/后书页」会被误当成角色。
    private static let objectTails: Set<String> = Set("""
    丹 丸 根 步 诀 术 经 典 功 法 阵 符 鼎 剑 刀 枪 甲 袍 衣 鞋 帽 铃 旗 镜 钟 丹药 灵药
    灵根 功法 身法 剑法 拳法 阵法 秘籍 书页 书册 木匣 玉盒 石室 山门 宗门
    """.split())
    private static func isNameTail(_ s: String) -> Bool {
        guard isHanString(s), s.count == 2 else { return false }
        if bodyNouns.contains(s) || blackRoots.contains(where: { s.contains($0) }) { return false }
        if objectTails.contains(where: { s.contains($0) }) { return false }
        if funcChars.contains(where: { s.contains($0) }) { return false }
        return true
    }

    // MARK: - stage 2: 全书词频（2~4 字汉字滑窗，等价于 jieba 切词词频但无需词典）
    private static func buildWordFreq(_ dialogues: [Dialogue]) -> [String: Int] {
        var freq: [String: Int] = [:]
        for d in dialogues {
            let chars = Array(d.text)
            // 只在连续汉字串内滑窗
            var run: [Character] = []
            func flush() {
                guard run.count >= 2 else { run.removeAll(); return }
                for L in 2...4 {
                    if run.count < L { continue }
                    for i in 0...(run.count - L) {
                        let w = String(run[i..<(i+L)])
                        freq[w, default: 0] += 1
                    }
                }
                run.removeAll()
            }
            for c in chars {
                if isHan(c) { run.append(c) } else { flush() }
            }
            flush()
        }
        return freq
    }

    // MARK: - stage 3: 候选打分发现
    private struct Scored {
        var score: Int
        var bind: Int
        var name: String
    }

    private static func discover(_ dialogues: [Dialogue], wordFreq: [String: Int]) -> [Scored] {
        var bindings: [String: Int] = [:]
        var ctx: [String: Int] = [:]
        for d in dialogues {
            for field in [d.pre, d.post] {
                let hits = nameCandidates(in: field)
                if let first = hits.first { bindings[first.1, default: 0] += 1 }
                // 紧贴边界共现：预/后置里像人名的片段
                for (pos, tok) in hits {
                    let dist = field.count - pos - tok.count
                    if dist <= 8 || pos == 0 {
                        ctx[tok, default: 0] += 1
                    }
                }
            }
        }
        // 候选池 = 说话位置候选 ∪ 高频上下文词
        var pool = Set(bindings.keys)
        for (w, c) in ctx where c >= 3 && (wordFreq[w] ?? 0) >= 3 { pool.insert(w) }
        var scored: [Scored] = []
        for name in pool {
            if generic.contains(name) { continue }
            let bind = bindings[name] ?? 0
            let c = ctx[name] ?? 0
            let wf = wordFreq[name] ?? 0
            let base = name.count == 2 ? 20 : (name.count == 3 ? 30 : 25)
            let score = base + bind * 8 + c * 2 + min(wf, 200) / 2
            if score >= 40 && (bind >= 3 || (c >= 3 && wf >= 5)) {
                scored.append(Scored(score: score, bind: bind, name: name))
            }
        }
        // 前缀碎片过滤：更短且更高分的前缀存在 → 丢弃
        scored.sort { ($0.score, -$0.name.count) > ($1.score, -$1.name.count) }
        let scoreByName = Dictionary(scored.map { ($0.name, $0.score) }, uniquingKeysWith: { a, _ in a })
        let names = Set(scored.map(\.name))
        var filtered: [Scored] = []
        for s in scored {
            var drop = false
            if s.name.count > 2 {
                for L in 2..<s.name.count {
                    let pre = String(s.name.prefix(L))
                    if names.contains(pre), (scoreByName[pre] ?? 0) > s.score { drop = true; break }
                }
            }
            if !drop { filtered.append(s) }
        }
        return filtered
    }

    // MARK: - stage 4: 别名合并（同姓身份称谓 → 该姓最高分具名角色，显著领先判据）
    private static func surname(of name: String) -> String {
        for cs in compoundSurnames where name.hasPrefix(cs) && name.count > cs.count { return cs }
        return name.first.map(String.init) ?? ""
    }
    private static func isTitleAlias(_ name: String) -> Bool {
        for t in aliasTitles where name.hasSuffix(t) && name.count > t.count { return true }
        return false
    }
    private static func mergeAliases(_ input: [Scored], wordFreq: [String: Int])
        -> (scored: [Scored], aliasMap: [String: String]) {
        let scoreByName = Dictionary(input.map { ($0.name, $0.score) }, uniquingKeysWith: { a, _ in a })
        let named = input.filter { !isTitleAlias($0.name) }
        var bySur: [String: [Scored]] = [:]
        for n in named { bySur[surname(of: n.name), default: []].append(n) }
        var aliasMap: [String: String] = [:]
        for s in input where isTitleAlias(s.name) {
            guard let cands = bySur[surname(of: s.name)] else { continue }
            let ranked = cands.sorted { $0.score > $1.score }
            let top = ranked.first?.score ?? 0
            let second = ranked.count > 1 ? ranked[1].score : 0
            if top >= 40 && top >= second * 3 {
                aliasMap[s.name] = ranked[0].name
            }
        }
        if aliasMap.isEmpty { return (input, [:]) }
        var mergedBind: [String: Int] = [:]
        for s in input { mergedBind[aliasMap[s.name] ?? s.name, default: 0] += s.bind }
        var out: [Scored] = []
        for (name, bind) in mergedBind {
            let base = name.count == 2 ? 20 : (name.count == 3 ? 30 : 25)
            let wf = wordFreq[name] ?? 0
            out.append(Scored(score: base + bind * 8 + min(wf, 200) / 2, bind: bind, name: name))
        }
        out.sort { $0.score > $1.score }
        return (out, aliasMap)
    }

    // MARK: - stage 5: 归属
    private static func gender(of name: String) -> Gender {
        var f = 0, m = 0
        for c in name {
            if femaleChars.contains(c) { f += 1 }
            if maleChars.contains(c) { m += 1 }
        }
        if f > m { return .female }
        if m > f { return .male }
        for k in ["娘子","夫人","师妹","仙子"] where name.contains(k) { return .female }
        for k in ["公子","少爷","大哥","道长"] where name.contains(k) { return .male }
        return .neutral
    }

    // MARK: - 对外入口
    public func analyze(_ text: String, userStopwords: Set<String> = [],
                        userWhitelist: Set<String> = []) -> AnalysisResult {
        let norm = Self.preprocess(text)
        let lines = Self.cleanLines(norm)
        let full = lines.joined(separator: "\n")
        let dialogues = Self.extractDialogues(full)
        let wf = Self.buildWordFreq(dialogues)
        var discovered = Self.discover(dialogues, wordFreq: wf).filter { !userStopwords.contains($0.name) }
        // 用户白名单词强制作为角色（出现即注册，绕过形态/频次门槛）
        for w in userWhitelist where !discovered.contains(where: { $0.name == w }) {
            let bind = dialogues.reduce(0) { acc, d in
                acc + (d.pre.contains(w) || d.post.contains(w) ? 1 : 0)
            }
            discovered.append(Scored(score: max(40, 20 + bind * 8), bind: bind, name: w))
        }
        let merged = Self.mergeAliases(discovered, wordFreq: wf)
        let scored = merged.scored
        let aliasMap = merged.aliasMap

        let roleNames = scored.map(\.name)
        let roleSet = Set(roleNames)
        let scoreByName = Dictionary(scored.map { ($0.name, $0.score) }, uniquingKeysWith: { a, _ in a })
        let bindByName = Dictionary(scored.map { ($0.name, $0.bind) }, uniquingKeysWith: { a, _ in a })

        // 年长尊称角色（老者绑定用），按分数降序，排除纯泛称
        var elder = roleNames.filter { r in
            !["老祖","老者"].contains(r) &&
            ["老","大夫","公","仙","翁","伯"].contains(where: { r.contains($0) })
        }
        elder.sort { (scoreByName[$0] ?? 0) > (scoreByName[$1] ?? 1) }

        // 构建角色对象（按频次 bind 降序，主角/高频在前）
        let ordered = scored.sorted { $0.bind > $1.bind }
        var roles: [CharacterRole] = []
        var idByName: [String: String] = [:]
        for (idx, s) in ordered.enumerated() {
            let g = Self.gender(of: s.name)
            let id = "role_\(idx)"
            idByName[s.name] = id
            let identity: RoleIdentity = idx == 0 ? .protagonist : (s.bind >= 5 ? .supporting : .extra)
            let hint = g == .male || g == .eunuch ? "male" : (g == .female ? "female" : "neutral")
            roles.append(CharacterRole(id: id, canonicalName: s.name, aliases: [s.name],
                                       gender: g, voiceHint: hint, identity: identity))
        }

        // 逐句归属
        var segments: [SpeechSegment] = []
        var lastNamed: String? = nil
        var pos = 0
        for d in dialogues {
            var sp: String? = nil
            if let h = Self.nameCandidates(in: d.post).first { sp = h.1 }
            if sp == nil, let h = Self.nameCandidates(in: d.pre).first { sp = h.1 }
            if let mapped = sp.flatMap({ aliasMap[$0] }) { sp = mapped }

            var genericHit: String? = nil
            for g in Self.refWords where d.post.contains(g) || d.pre.contains(g) { genericHit = g; break }

            var speaker: String? = nil
            if let s = sp, roleSet.contains(s) {
                speaker = s; lastNamed = s
            } else if genericHit != nil || (sp.map { Self.generic.contains($0) || $0.contains("老") } ?? false) {
                if let g = genericHit, ["老者","这名老者","那老者"].contains(g), let e = elder.first {
                    speaker = e
                } else {
                    speaker = lastNamed
                }
            }
            if let mapped = speaker.flatMap({ aliasMap[$0] }) {
                speaker = mapped; lastNamed = mapped
            }
            let cid = speaker.flatMap { idByName[$0] }
            segments.append(SpeechSegment(id: "seg_\(pos)", text: d.text,
                                          characterId: cid, emotion: .neutral, position: pos))
            pos += 1
        }
        return AnalysisResult(roles: roles, segments: segments)
    }
}
