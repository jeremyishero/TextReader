import Foundation

/// 情绪类型：对应 喜怒哀乐（+ 中性旁白）。
public enum Emotion: String, Codable, CaseIterable, Sendable {
    case neutral
    case joy       // 喜
    case anger     // 怒
    case sorrow    // 哀
    case happiness // 乐
}

/// 朗读发音参数（离线 TTS 仅支持 rate / pitch / volume）。
public struct Prosody: Sendable {
    public var rate: Float
    public var pitch: Float
    public var volume: Float
    public init(rate: Float, pitch: Float, volume: Float) {
        self.rate = rate
        self.pitch = pitch
        self.volume = volume
    }
}

public extension Emotion {
    /// 将情绪映射为可执行的朗读参数。baseRate 为用户设定的全局语速（内部标度：0.5=正常人语速）。
    /// 离线语音能力有限，仅以 rate/pitch/volume 区分情绪。
    func prosody(baseRate: Float = 0.5) -> Prosody {
        let clamped = min(max(baseRate, 0.1), 2.0)
        switch self {
        case .neutral:
            return Prosody(rate: clamped, pitch: 1.0, volume: 1.0)
        case .joy:
            return Prosody(rate: min(clamped * 1.1, 2.0), pitch: 1.10, volume: 1.0)
        case .happiness:
            return Prosody(rate: min(clamped * 1.15, 2.0), pitch: 1.15, volume: 1.05)
        case .anger:
            return Prosody(rate: min(clamped * 1.20, 2.0), pitch: 1.15, volume: 1.10)
        case .sorrow:
            return Prosody(rate: max(clamped * 0.80, 0.1), pitch: 0.85, volume: 0.90)
        }
    }
}

/// 情绪词表与识别：对话前的「说/道」提示词 + 引语内情绪词，双重识别。
public struct EmotionLexicon {

    /// 喜（笑、欢喜）
    public static let joyCues = ["笑", "喜", "欢", "含笑", "微笑", "大笑", "笑吟吟", "嘻", "欣", "雀跃", "乐呵呵", "喜道", "笑道"]
    /// 乐（愉悦、轻快）
    public static let happyCues = ["乐", "雀跃", "欢快", "开怀", "畅快", "愉", "快活"]
    /// 怒
    public static let angerCues = ["怒", "喝", "骂", "愤", "斥", "吼", "咆哮", "冷笑", "大喝", "叱", "瞪", "厉声", "恨", "咬牙"]
    /// 哀
    public static let sorrowCues = ["哭", "泪", "悲", "叹", "伤", "哀", "泣", "呜咽", "抽噎", "凄", "怅", "愁", "哽咽", "垂泪", "心酸"]

    private static func containsAny(_ text: String, _ cues: [String]) -> Bool {
        cues.contains { text.contains($0) }
    }

    /// 识别一段对话的情绪：引语前的提示词优先，其次引语内情绪词，最后中性。
    /// - Parameters:
    ///   - before: 引语前的叙述文本（含「X 说/道」等提示）
    ///   - quote: 引语正文
    public static func detect(before: String, quote: String) -> Emotion {
        if containsAny(before, angerCues) { return .anger }
        if containsAny(before, sorrowCues) { return .sorrow }
        if containsAny(before, joyCues) { return .joy }
        if containsAny(before, happyCues) { return .happiness }

        if containsAny(quote, angerCues) { return .anger }
        if containsAny(quote, sorrowCues) { return .sorrow }
        if containsAny(quote, happyCues) { return .happiness }
        if containsAny(quote, joyCues) { return .joy }

        return .neutral
    }
}
