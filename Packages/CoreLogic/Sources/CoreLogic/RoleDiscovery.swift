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
    """.split(separator: " ").map(String.init))

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
    """.split(separator: " ").map(String.init))

    // 身份后缀：可与姓组成称呼（岳堂主/墨大夫/厉师兄）
    private static let personTitles: Set<String> = Set("""
    堂主 护法 大夫 长老 门主 宗主 掌门 教习 管家 伙计 少爷 公子 先生 大人 老者 少年 少女 姑娘
    夫人 娘子 仙子 道友 师兄 师弟 师姐 师妹 老 爷 公 伯 叔 哥 姐 弟 妹 婆 娘 父 兄 嫂 王 将 相 侯
    """.split(separator: " ").map(String.init))

    // 身体/感知名词：不拼进人名（挡「韩立目光」）
    private static let bodyNouns: Set<String> = Set("""
    目光 神色 声音 脸色 表情 语气 眼神 身影 举止 言语 话语 心头 心中 脑中 大笑 冷笑 微笑 沉默
    点头 摇头 皱眉 口气 脚步 手掌 肩膀 身躯
    """.split(separator: " ").map(String.init))

    private static let compoundSurnames: Set<String> = Set("""
    欧阳 太史 端木 上官 司马 东方 独孤 南宫 万俟 闻人 夏侯 诸葛 尉迟 皇甫 宗政 濮阳 公冶 太叔
    申屠 公孙 慕容 仲孙 轩辕 令狐 宇文 长孙 司徒 司空 澹台 公羊 赫连
    """.split(separator: " ").map(String.init))

    // 泛称指代：不作为正式角色，但绑定说话人
    private static let refWords: Set<String> = Set("这名老者 那老者 老者 此人 那人 对方".split(separator: " ").map(String.init))

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

    // 别名身份后缀（厉师兄→厉飞雨）——只保留纯身份称谓；
    // 「大夫/掌柜/管家/少爷/公子」是独立实名角色（墨大夫/田掌柜），绝不能当别名合并掉。
    private static let aliasTitles: [String] = [
        "师兄","师弟","师姐","师妹","师叔","师伯","师姑","师侄"
    ].sorted { $0.count > $1.count }

    private static let blackRoots: Set<String> = Set("""
    宗 门 谷 山 殿 城 府 阁 楼 院 观 寺 诀 术 剑 丹 符 鼎 铃 旗 镜 钟 天地 江湖 黄昏 清晨
    深夜 此时 此刻 东方 西方 南方 北方
    """.split(separator: " ").map(String.init))

    // 虚词/动词字：候选片段含这些字 → 不是名词性称呼
    private static let funcChars: Set<Character> = Set("""
    的地得了着过是在有也就还都被把让给对向跟与或而之其这那哪谁什么不没很太更最又再才只已将
    从于为以并且但则若如虽即而何况乎哉矣焉耳说道问答喊叫笑叹哭应回劝禀奏言吟呼唤喝骂斥吼叱
    嘀咕嘟囔念叨咕哝嚷吩咐补充
    """)

    // 女性/男性名字特征字（与 PC 端 gender_of 一致）
    private static let femaleChars: Set<Character> = Set("婷娟秀丽燕玲芳娜静淑惠美倩雪梅兰竹菊莲茹薇雅婉馨怡悦欣彤丹琳璐瑾萱萌蕊婧韵娇萍霞月盈依曼柔诗梦琪瑶嫣晴芸菲茜露霜娘婆母姐妹姑姨嫂妃")
    private static let maleChars: Set<Character> = Set("伟强刚勇军杰涛峰毅宇浩凯鹏斌波辉龙飞磊旭昊辰轩睿铭铠铮铁雄豪俊彦国华德建永昌盛邦振耀阳海山岩松柏锋剑彪郎伯叔父兄舅爷公")

    // ---- 人名用字表：名（去掉姓之后的部分）必须含这些字，否则多半是普通词 ----
    // 合并 GenderLexicon 男女名字常用字，再补凡人等书中常见名用字。
    private static let nameChars: Set<Character> = {
        var s = GenderLexicon.maleNameChars.union(GenderLexicon.femaleNameChars)
        for c in "立雨舞彩环巧凝云天龙倩婉柔静馨盈才义礼飞羽清玄真玄机妙慈航化元古风雷鸣山川海江河湖星辰日月金玉田力士心" { s.insert(c) }
        return s
    }()

    // ---- 非人名常用词黑名单：时间词/副词/动词/外貌描述/泛称，一律不作角色 ----
    private static let nonPersonWords: Set<String> = Set("""
    有时候 时间 时辰 时候 马上 路上 明显 冷静 后他 后来 传来 后传来 时辰后 半晌 片刻 良久 许久
    随即 立刻 此时 此刻 之后 之前 这时 那时 一时 顿时 骤然 忽然 果然 竟然 显然 自然 当然
    高男子 高瘦 红脸老 方脸修 吕姓修 须大汉 金光上 祖师 李师祖 金老怪 大衍神 老大 老二 老三
    师兄 师叔 师伯 师姑 师侄 老者 老怪 大汉 男子 女子 汉子 修士 凡人 武者 高手 壮汉
    老者一 老者二 老者三 老者听 老者见 后传来 金光上 高瘦 高矮 方脸 红脸 白脸 黑脸
    """.split(separator: " ").map(String.init))
    // 这些前缀一出现即非人名（老者X / 时间X / 之后X）
    private static let badNamePrefixes = ["老者", "时间", "时辰", "之后", "之前", "这时候", "那时候", "半晌", "片刻"]

    /// 是否是非人名常用词（黑名单最高优先级，不受高频兜底影响）
    private static func isNonPersonWord(_ s: String) -> Bool {
        if nonPersonWords.contains(s) { return true }
        for p in badNamePrefixes where s.hasPrefix(p) { return true }
        // 外貌描述类：含「脸/瘦/胖/矮/须/鬓」等字的多半是描写词（不含高/金，避免误杀高姓金姓）
        if s.contains(where: { (["脸","瘦","胖","矮","须","鬓","姓"] as [Character]).contains($0) }) { return true }
        return false
    }

    /// 名（去姓后的部分）是否像真人名：至少含一个名字常用字
    private static func looksLikeGiven(_ given: String) -> Bool {
        guard (1...3).contains(given.count), isHanString(given), !isNonPersonWord(given) else { return false }
        return given.contains { nameChars.contains($0) }
    }

    // ---------- 对话切分 ----------
    private struct Dialogue {
        var pre: String
        var post: String
        var text: String
        /// 正双引号紧前面是否有冒号（：/:）——只有「韩立说道：“…”」这种才是角色对话；
        /// 无冒号的引号内容（如强调、书名号式引用）按旁白读，不切换角色声音。
        var hasColon: Bool = false
        /// 该引号在全文中的字符区间 [quoteStart, quoteEnd)，用于把引号外的旁白也切成段。
        /// quoteStart 指正引号位置，quoteEnd 指反引号后一位。
        var quoteStart: Int = 0
        var quoteEnd: Int = 0
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
            // 正引号前面紧邻的字符必须是冒号（：或 :），才是「某人说道：“…”」的角色对话。
            // 无冒号的引号内容（引用/强调/书名）按旁白处理，不切换角色声音。
            let hasColon = i > 0 && (chars[i - 1] == "：" || chars[i - 1] == ":")
            res.append(Dialogue(pre: pre, post: post, text: qtext, hasColon: hasColon,
                                quoteStart: i, quoteEnd: qend))
            i = qend
        }
        return res
    }

    // MARK: - stage 1: 说话位置候选（形态规则替代 jieba 词性）

    /// 把片段切成「词」：这里不做真分词，而是从每个位置尝试抽名词性候选（2~4字）。
    /// 返回 [(位置, 候选)]，候选已过形态门槛。
    private static func nameCandidates(in frag: String) -> [(Int, String)] {
        // 剥掉前导非汉字（引号/空白/标点）——跨行时 pre 常带上一句的收尾引号，
        // 若不剥，「小算盘」的「小」不在段首，绰号/主语判断会失效。
        var leading = 0
        let allChars = Array(frag)
        while leading < allChars.count && !isHan(allChars[leading]) { leading += 1 }
        let chars = Array(allChars[leading...])
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
            // a0) 绰号：段首「小/老/大/阿 + 2字」，独立成候选（小算盘/老狐狸）。
            //     直接放行，绕开 isNameLike 的姓表与词根门槛——绰号本就不靠姓氏。
            if i == 0, active.count >= 3, "小老大阿".contains(active[0]) {
                let nick = String(active[0...2])
                // 收紧：排除「老者一/高男子」等黑名单与外貌词；尾字须像名用字
                if isHanString(nick), !generic.contains(nick), !bodyNouns.contains(nick),
                   !isNonPersonWord(nick),
                   looksLikeGiven(String(nick.dropFirst())) || nick.hasSuffix("盘") {
                    hits.append((0, nick))
                }
            }
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
                    // 收紧：名尾两字必须含名字常用字，挡掉「马上/路上/时候/冷静/后他」等
                    if looksLikeGiven(next2), !isNonPersonWord(String(active[i...i+2])) {
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
        // 非人名常用词黑名单最高优先级
        if isNonPersonWord(tok) { return false }
        if generic.contains(tok) { return false }
        if tok.contains(where: { funcChars.contains($0) }) { return false }
        if blackRoots.contains(where: { tok.contains($0) }) { return false }
        if objectTails.contains(where: { tok.contains($0) }) { return false }
        let chars = Array(tok)
        // 独立姓名：姓 + 名（名须含名字常用字，挡掉「时候/后他/马上/冷静」）
        if discoverySurnames.contains(String(chars[0])) {
            let given = String(chars.dropFirst())
            // 「墨大夫/岳堂主」这类 姓+身份称谓 是合法角色，必须放行
            if personTitles.contains(given) { return true }
            if looksLikeGiven(given) { return true }
        }
        for cs in compoundSurnames where tok.hasPrefix(cs) {
            let given = String(chars.dropFirst(cs.count))
            return !given.isEmpty && looksLikeGiven(given)
        }
        // 绰号：段首「小/老/大/阿 + 2字」，名部分须像名（小算盘）
        if atSegmentStart, tok.count == 3, "小老大阿".contains(chars[0]),
           looksLikeGiven(String(chars.dropFirst())) || tok.hasSuffix("盘") {
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
    """.split(separator: " ").map(String.init))
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
    /// 性别判定：称谓优先 → 关系词 → 名用字投票（跳过姓氏字，避免「燕家老」因姓「燕」误判女）
    /// → 主角兜底（台词数第一且完全无线索时按男，韩立即此情况）。
    private static func gender(of name: String, isProtagonist: Bool) -> Gender {
        // 1) 完整称呼/称谓（大夫→男、娘子→女等），长词优先
        if let g = GenderLexicon.titleGender(name) { return g }
        // 2) 去掉姓氏后，用关系词判定（三娘→娘→女）
        let sur = surname(of: name)
        let given = String(name.dropFirst(sur.count))
        if let g = GenderLexicon.relationGender(given) { return g }
        // 3) 名用字投票：姓氏字不参与（燕是姓，不算女性字）
        var f = 0, m = 0
        for c in given {
            // given 已去掉姓氏首字，名里的字都参与投票（「墨凤舞」的「凤」虽也是姓氏，但此处是名用字）
            if GenderLexicon.femaleNameChars.contains(c) || femaleChars.contains(c) { f += 1 }
            if GenderLexicon.maleNameChars.contains(c) || maleChars.contains(c) { m += 1 }
        }
        if f > m { return .female }
        if m > f { return .male }
        // 4) 主角兜底：完全无线索时按男（小说主角默认男，覆盖韩立/墨大夫这类无性别字姓名）
        if isProtagonist { return .male }
        return .neutral
    }

    /// 年龄判定：称谓关键词优先（老者/童子/少年等），再看名字里的年龄用字，
    /// 无年龄线索默认 youth（青年）。alias 一并检查——「韩立/韩兄」里的「兄」不算老。
    private static func age(of name: String, aliases: [String] = []) -> Age {
        let all = [name] + aliases
        // 老年线索：老/翁/婆/妪/公/叟/祖 + 长尊称
        let seniorWords: [String] = ["老祖","老怪","老者","老翁","老妪","老妇","老婆","老道","老汉","太上","尊者",
                                     "仙翁","道翁","祖父","曾祖","师祖","祖师","长老","前辈","老朽","老夫"]
        for w in all where seniorWords.contains(where: { w.contains($0) }) { return .senior }
        // 中年线索：中年/大汉/壮汉/掌柜/大夫/将军（成年但不老）
        let adultWords: [String] = ["中年","壮汉","大汉","掌柜","大夫","将军","掌门","门主","宗主","当家"]
        for w in all where adultWords.contains(where: { w.contains($0) }) { return .adult }
        // 童年线索：童/小孩/孩童/幼
        let childWords: [String] = ["童子","小孩","孩童","幼童","小娃","童儿"]
        for w in all where childWords.contains(where: { w.contains($0) }) { return .child }
        // 少年线索：少年/少侠/小姐(年轻女)/公子/少爷 + 「小」 prefix 绰号
        let teenWords: [String] = ["少年","少侠","少女","小姐","公子","少爷","少主","小算盘"]
        for w in all where teenWords.contains(where: { w.contains($0) }) { return .teen }
        // 名字用字兜底：老/翁→senior，童/娃→child（仅当出现在名尾，避免误判姓）
        let given = String(name.dropFirst(surname(of: name).count))
        if given.contains(where: { ["老","翁","叟"].contains($0) }) { return .senior }
        return .youth
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
        for w in userWhitelist where !discovered.contains(where: { $0.name == w }) {
            let bind = dialogues.reduce(0) { acc, d in
                acc + (d.pre.contains(w) || d.post.contains(w) ? 1 : 0)
            }
            discovered.append(Scored(score: max(40, 20 + bind * 8), bind: bind, name: w))
        }
        let merged = Self.mergeAliases(discovered, wordFreq: wf)
        let scored = merged.scored
        let aliasMap = merged.aliasMap

        let roleSet = Set(scored.map(\.name))
        let scoreByName = Dictionary(scored.map { ($0.name, $0.score) }, uniquingKeysWith: { a, _ in a })

        // 年长尊称角色（老者绑定用）
        let elder = roleSet.filter { r in
            !["老祖","老者"].contains(r) &&
            ["老","大夫","公","仙","翁","伯"].contains(where: { r.contains($0) })
        }.sorted { (scoreByName[$0] ?? 0) > (scoreByName[$1] ?? 1) }

        // ---- 第一趟：给每段对白归属说话人（name），并统计每个角色的真实台词数 ----
        var speakerByDialogue: [Int: String] = [:]     // dialogue index → 归一后的角色主名
        var lastNamed: String? = nil
        for (di, d) in dialogues.enumerated() {
            guard d.hasColon else { continue }          // 无冒号引号不算角色台词
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
            if let s = speaker, roleSet.contains(s) { speakerByDialogue[di] = s }
        }
        // 真实台词数（只统计归属到角色的对白）
        var quoteCount: [String: Int] = [:]
        for (_, name) in speakerByDialogue { quoteCount[name, default: 0] += 1 }

        // ---- 构建角色：按真实台词数降序，剔除 0 台词与噪声，最多 48 个 ----
        // 噪声过滤：名字必须来自 discover 的准入候选，且满足「至少 1 次真实台词」；
        // 像「马上/冷冷/大衍神」这类在正文里被误当说话人的词，通常 bind 低且台词数少，
        // 这里再用 isNoisyName 兜一层。
        let eligible = scored.filter { s in
            (quoteCount[s.name] ?? 0) > 0 && !Self.isNoisyName(s.name)
        }
        let ordered = Array(eligible.sorted {
            let a = quoteCount[$0.name] ?? 0, b = quoteCount[$1.name] ?? 0
            if a != b { return a > b }
            return $0.score > $1.score
        }.prefix(48))

        var roles: [CharacterRole] = []
        var idByName: [String: String] = [:]
        for (idx, s) in ordered.enumerated() {
            let g = Self.gender(of: s.name, isProtagonist: idx == 0)
            let a = Self.age(of: s.name)
            let id = "role_\(idx)"
            idByName[s.name] = id
            let identity: RoleIdentity = idx == 0 ? .protagonist : (idx < 10 ? .supporting : .extra)
            let hint = g == .male || g == .eunuch ? "male" : (g == .female ? "female" : "neutral")
            roles.append(CharacterRole(id: id, canonicalName: s.name, aliases: [s.name],
                                       gender: g, age: a, voiceHint: hint, identity: identity))
        }

        // ---- 第二趟：按全文顺序输出 segments（旁白 + 对白），保证朗读覆盖全文 ----
        var segments: [SpeechSegment] = []
        let chars = Array(full)
        var cursor = 0
        func appendNarration(_ range: Range<Int>) {
            let raw = String(chars[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            for piece in Self.splitNarration(raw) {
                segments.append(SpeechSegment(id: "seg_\(segments.count)", text: piece,
                                              characterId: nil, emotion: .neutral,
                                              position: segments.count))
            }
        }
        for (di, d) in dialogues.enumerated() {
            // 引号之前的正文 → 旁白段
            if d.quoteStart > cursor { appendNarration(cursor..<d.quoteStart) }
            // 引号内容 → 角色台词（有冒号且归属到角色）或旁白（无冒号/未归属）
            let cid = speakerByDialogue[di].flatMap { idByName[$0] }
            segments.append(SpeechSegment(id: "seg_\(segments.count)", text: d.text,
                                          characterId: cid, emotion: .neutral,
                                          position: segments.count))
            cursor = d.quoteEnd
        }
        if cursor < chars.count { appendNarration(cursor..<chars.count) }
        return AnalysisResult(roles: roles, segments: segments)
    }

    /// 把一大段旁白按标点切成适合 TTS 的小段（≤160字），避免单次合成过长。
    private static func splitNarration(_ s: String) -> [String] {
        guard !s.isEmpty else { return [] }
        var result: [String] = []
        for para in s.split(separator: "\n") {
            let p = para.trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty else { continue }
            var cur = ""
            for ch in p {
                cur.append(ch)
                if "。！？!?；;".contains(ch), cur.count >= 40 {
                    result.append(cur); cur = ""
                } else if cur.count >= 160 {
                    result.append(cur); cur = ""
                }
            }
            if !cur.isEmpty { result.append(cur) }
        }
        return result
    }

    /// 噪声角色名过滤：明显的非人名/误识别词
    private static func isNoisyName(_ name: String) -> Bool {
        if name.count < 2 || name.count > 4 { return true }
        // 非人名常用词（时间/副词/动词/外貌/泛称）——最高优先级
        if isNonPersonWord(name) { return true }
        if generic.contains(name) || bodyNouns.contains(name) { return true }
        if name.contains(where: { funcChars.contains($0) }) { return true }
        if objectTails.contains(where: { name.contains($0) }) { return true }
        // 纯称谓/外貌结尾：老者X、师兄、师叔、红脸老、方脸修、须大汉、金老怪、X姓X
        if ["者","兄","叔","伯","姑","侄","祖师","老怪","大汉","男子","女子","修","汉"].contains(where: { name.hasSuffix($0) }) { return true }
        // 「吕姓修」这类「X姓X」结构，非实名
        if name.contains("姓") { return true }
        return false
    }
}
