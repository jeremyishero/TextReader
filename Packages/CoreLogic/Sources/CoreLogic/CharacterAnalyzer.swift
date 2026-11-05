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
    private let speechCues = "说|道|曰|问|答|喊|叫|笑|怒道|冷笑|大喝|厉声|低声|轻声|高声|叹|哭|喜|愤|应|回|劝|禀|奏|言|吟|呼|唤|喝|骂|斥|吼|咆哮|叱|瞪|咬牙|扯|嘀咕|嘟囔|嘟哝|念叨|咕哝|嚷|吩咐|补充|道：|说："
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

        // ---- Pass 1：说话人候选计数（所有长度；三字及以上构成「长名」） ----
        var speakerCounts: [String: Int] = [:]
        for unit in units {
            if case .dialogue(_, let preceding) = unit {
                if let raw = resolveSpeaker(preceding, blocked: blocked, whitelist: whitelist), raw != "他", raw != "她" {
                    speakerCounts[raw, default: 0] += 1
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
            // 白名单词一定是人名，直接准入
            if whitelist.contains(c) { return true }
            switch c.count {
            case 2:
                // 旁白 + 说话人 总出现 ≥2 次（垃圾已被清洗/停用词/长名占位拦截）
                return (narrationCounts[c] ?? 0) + (speakerCounts[c] ?? 0) >= 2
            case 3:
                return (speakerCounts[c] ?? 0) >= 2
            default:
                return false
            }
        }
        func isFragment(_ c: String) -> Bool {
            if whitelist.contains(c) { return false }
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
                    if want == nil || g == want { return last }
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

    /// 从引语前的叙述里找最近一次「X [+地/得/了] + 说话提示」，返回 X（已清洗）。
    /// 副词修饰（「眉飞色舞地道」「缓缓地说」）与量词前缀（「一张脸说」）的捕获不可靠，跳过。
    private func resolveSpeaker(_ preceding: String, blocked: Set<String>, whitelist: Set<String> = []) -> String? {
        let last = String(preceding.suffix(min(preceding.count, 40)))
        let pattern = "([\\u4e00-\\u9fa5]{1,4})([地得了]?)(?:\(speechCues))"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = last as NSString
        let range = NSRange(location: 0, length: ns.length)
        let matches = re.matches(in: last, range: range)
        var out: String? = nil
        for m in matches.reversed() {
            guard m.range(at: 2).location != NSNotFound else { continue }
            if m.range(at: 2).length > 0 { continue }   // 副词修饰 → 不可靠
            let start = m.range(at: 1).location
            if start > 0, Self.measurePrev.contains(Character(ns.substring(with: NSRange(location: start - 1, length: 1)))) {
                continue
            }
            if let c = cleanCandidate(ns.substring(with: m.range(at: 1)), blocked: blocked, whitelist: whitelist) {
                out = c
                break
            }
        }
        return out
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
        "好意思", "乐意", "费力", "包扎", "马车", "马鞭", "高挂"
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
