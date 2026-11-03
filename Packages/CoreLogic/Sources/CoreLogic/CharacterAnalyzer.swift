import Foundation

// MARK: - 分析产出模型

/// 书中被识别出的一个角色（可能由姓名、称谓、代词、描述词合并而来）。
public struct CharacterRole: Identifiable, Codable {
    public var id: String
    public var canonicalName: String      // 主名称（通常为首次出现的姓名）
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
public struct CharacterAnalyzer {

    /// 说话提示词（出现在引语前，用于定位说话人）
    private let speechCues = "说|道|曰|问|答|喊|叫|笑|怒道|冷笑|大喝|厉声|低声|轻声|高声|叹|哭|喜|愤|应|回|劝|禀|奏|言|吟|呼|唤|喝|骂|斥|吼|咆哮|叱|瞪|咬牙|道：|说："
    /// 去除姓名前后称谓/敬语，得到基名。
    /// 注意：描述词（那少年/那女子/这丫头等）不在此列，以免「那少年」被误剥成「那」。
    private let trailingTitles = ["娘子","丫鬟","少爷","老爷","夫人","王爷","相公","女侠","仙子","侠士","老爷子","公主","郡主","皇后","太后","妃","妾","妻","姊","妹","嫂","姑","婆","姨","婶","媳","女儿","姐","弟","叔","伯","舅","父","夫","兄","哥","郎","爹","爸","爷","子","婿","郎君","将军","殿下"]
    /// 描述词 → 性别（那少年 / 那女子 等）
    private let descriptorGender: [String: Gender] = [
        "那少年": .male, "那书生": .male, "那公子": .male, "那青年": .male, "那老者": .male, "这少年": .male, "那汉子": .male,
        "那女子": .female, "那丫头": .female, "这丫头": .female, "那小姐": .female, "那妇人": .female, "这女子": .female, "那姑娘": .female
    ]

    public init() {}

    // MARK: 主入口

    public func analyze(_ text: String) -> AnalysisResult {
        let units = segmentText(text)

        var roles: [CharacterRole] = []
        var aliasToRole: [String: String] = [:]
        var sceneRecent: [String] = []   // 当前场景内最近出现过的角色 id（用于代词/描述词回指）
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
        /// 解析代词（他/她）到最近同性别角色
        func resolvePronoun(_ p: String) -> String? {
            if p == "她" {
                return sceneRecent.last(where: { roleGender($0) == .female })
            } else {
                return sceneRecent.last(where: { roleGender($0) == .male }) ?? sceneRecent.last
            }
        }

        for unit in units {
            switch unit {
            case .narration(let t):
                if isChapterMarker(t) { sceneRecent.removeAll() }
                // 在旁白中登记被提及（带说话提示）的角色，建立场景上下文
                for name in extractNamesWithCue(t) {
                    let id = registerOrMerge(surface: name)
                    ensureSceneRecent(id)
                }
                segments.append(SpeechSegment(id: "seg_\(segIndex)", text: t, characterId: nil, emotion: .neutral, position: segIndex))
                segIndex += 1

            case .dialogue(let quote, let preceding):
                let emotion = EmotionLexicon.detect(before: preceding, quote: quote)
                var speakerId: String? = nil
                if let raw = resolveSpeaker(preceding) {
                    if raw == "他" || raw == "她" {
                        if let id = resolvePronoun(raw) {
                            addAlias(raw, to: id)
                            speakerId = id
                        }
                    } else if let g = descriptorGender[raw] {
                        // 描述词：并入同场景最近同性别角色，否则新建
                        if let id = sceneRecent.last(where: { roleGender($0) == g }) {
                            addAlias(raw, to: id)
                            speakerId = id
                        } else {
                            speakerId = registerOrMerge(surface: raw)
                        }
                    } else {
                        speakerId = registerOrMerge(surface: raw)
                    }
                }
                if let id = speakerId { ensureSceneRecent(id) }
                segments.append(SpeechSegment(id: "seg_\(segIndex)", text: quote, characterId: speakerId, emotion: emotion, position: segIndex))
                segIndex += 1
            }
        }

        return AnalysisResult(roles: roles, segments: segments)
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

    // MARK: 说话人解析

    /// 从引语前的叙述里找最近一次「X + 说话提示」，返回 X（已去称谓）。
    private func resolveSpeaker(_ preceding: String) -> String? {
        let last = String(preceding.suffix(min(preceding.count, 40)))
        let pattern = "([\\u4e00-\\u9fa5]{1,4})(?:\(speechCues))"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = last as NSString
        let range = NSRange(location: 0, length: ns.length)
        let results = re.matches(in: last, range: range)
        guard let lastMatch = results.last, lastMatch.numberOfRanges > 1 else { return nil }
        let name = ns.substring(with: lastMatch.range(at: 1))
        // 保留原始称呼（如「林兄」「苏姑娘」），归一化由 registerOrMerge/resolveAlias 处理，
        // 以保证别名（林兄、那少年）能正确并入对应角色。
        return name.isEmpty ? nil : name
    }

    /// 在旁白里提取所有「X + 说话提示」的 X，用于建立角色与场景上下文。
    private func extractNamesWithCue(_ text: String) -> [String] {
        let pattern = "([\\u4e00-\\u9fa5]{1,4})(?:\(speechCues))"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        let results = re.matches(in: text, range: range)
        return results.compactMap { m -> String? in
            guard m.numberOfRanges > 1 else { return nil }
            let name = ns.substring(with: m.range(at: 1))
            let n = normalizeName(name)
            return n.isEmpty ? nil : n
        }
    }

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
