import Foundation
import AVFoundation
import CoreLogic

/// 朗读控制器：封装 AVSpeechSynthesizer + 云端 TTS 备选通道。
/// - 支持「未解析」模式（直接按句朗读）与「角色分声」模式（按分析结果朗读）。
/// - 角色用各自声音；情绪通过 rate/pitchMultiplier/volume 表达；旁白用中性默认声。
/// - 支持从指定段索引续读（进度记忆）；onIndexChange 供 UI 持久化进度。
/// - 支持简繁/中英自动切声（按段文本判定语言，选用对应声音）。
/// - 云端 TTS：优先走用户配置的云端接口合成，失败自动回退本地合成。
@MainActor
final class TTSPlayer: NSObject, ObservableObject {
    @Published var isPlaying = false
    /// 语速（显示标度）：1.0 = 正常人语速，范围 0.5–3.0。
    /// 内部朗读时乘以 rateScale 换算为 AVSpeechUtterance 标度（其 0.5 = 正常语速）。
    @Published var rate: Float = 1.0
    @Published var currentSegmentIndex: Int = -1
    /// 当前正在朗读的文本（供阅读页同步高亮段落）
    @Published var nowSpeakingText: String?

    /// 显示语速 → AVSpeech 内部语速 的换算系数（AVSpeech 的 0.5 = 正常语速）
    static let rateScale: Float = 0.5

    /// 每读到一个新段/分块回调一次（供 ReadingView 保存进度）
    var onIndexChange: ((Int, Bool) -> Void)?   // (index, isAnalyzedMode)

    /// 云端合成失败回退本地时回调一次（供 UI 弹出轻提示，不再静默回退）
    var onCloudFallback: (() -> Void)?

    private let synth = AVSpeechSynthesizer()
    private var segments: [SpeechSegment] = []
    private var plainChunks: [String] = []
    private var roleVoices: [String: AVSpeechSynthesisVoice] = [:]
    private var defaultVoice: AVSpeechSynthesisVoice?
    private var languageVoices: [ScriptLanguage: AVSpeechSynthesisVoice] = [:]
    var autoVoiceSwitch = true
    private var currentIndex = 0
    private var mode: PlayMode = .plain

    /// 云端合成闭包（由 App 层注入）；返回 nil 表示失败，将回退本地。
    var cloudProvider: ((String) async -> Data?)?
    private var useCloud = false
    private var audioPlayer: AVAudioPlayer?

    private enum PlayMode { case plain, segments }

    override init() {
        super.init()
        synth.delegate = self
    }

    // MARK: 声音配置

    /// 按语言与性别挑选离线语音（AVSpeechSynthesisVoice 不直接暴露性别，用名称关键词兜底）。
    static func pickVoice(language: String = "zh-CN", preferGender: Gender? = nil) -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(language) }
        if let g = preferGender, g != .neutral {
            let keyword = g == .male ? "Male" : "Female"
            if let v = voices.first(where: { $0.name.contains(keyword) }) { return v }
        }
        return voices.first ?? AVSpeechSynthesisVoice(language: language)
    }

    func setRoleVoices(_ map: [String: AVSpeechSynthesisVoice]) { roleVoices = map }
    func setDefaultVoice(_ v: AVSpeechSynthesisVoice?) { defaultVoice = v }
    func setLanguageVoices(_ map: [ScriptLanguage: AVSpeechSynthesisVoice]) { languageVoices = map }

    /// 按性别池 + 轮转为各角色分配声音：
    /// - 男角色从「男声池」取、女角色从「女声池」取、中性/未知从「中性池」取；
    /// - 同一性别的不同角色依次轮转池内不同声音（男 A / 男 B 声音不同）；
    /// - 按 role.id 分配一次，同一角色（含所有别名）全程固定同一声音；
    /// - 池为空时借用其他池兜底，保证每个角色都有声音。
    /// 声音性别依据系统声音名称中的 Male/Female/男/女 关键词（注意先判 Female 再判 Male）。
    static func assignVoices(roles: [CharacterRole]) -> [String: AVSpeechSynthesisVoice] {
        let all = AVSpeechSynthesisVoice.speechVoices()
        let zh = all.filter { $0.language.hasPrefix("zh") }
        let poolBase = zh.isEmpty ? all : zh

        var malePool: [AVSpeechSynthesisVoice] = []
        var femalePool: [AVSpeechSynthesisVoice] = []
        var neutralPool: [AVSpeechSynthesisVoice] = []
        for v in poolBase {
            let n = v.name
            if n.contains("Female") || n.contains("female") || n.contains("女") {
                femalePool.append(v)
            } else if n.contains("Male") || n.contains("male") || n.contains("男") {
                malePool.append(v)
            } else {
                neutralPool.append(v)
            }
        }
        if malePool.isEmpty { malePool = Array((neutralPool + femalePool).prefix(2)) }
        if femalePool.isEmpty { femalePool = Array((neutralPool + malePool).prefix(2)) }
        if neutralPool.isEmpty { neutralPool = poolBase }

        var out: [String: AVSpeechSynthesisVoice] = [:]
        var mi = 0, fi = 0, ni = 0
        for role in roles {
            switch role.gender {
            case .male:
                if !malePool.isEmpty { out[role.id] = malePool[mi % malePool.count]; mi += 1 }
            case .female:
                if !femalePool.isEmpty { out[role.id] = femalePool[fi % femalePool.count]; fi += 1 }
            case .neutral:
                if !neutralPool.isEmpty { out[role.id] = neutralPool[ni % neutralPool.count]; ni += 1 }
            }
        }
        // 补漏（池被借空等极端情况）
        for role in roles where out[role.id] == nil {
            if !poolBase.isEmpty {
                out[role.id] = poolBase[abs(role.id.hashValue) % poolBase.count]
            }
        }
        return out
    }

    /// 按文本语言选声（自动切声开启时生效）。
    private func voiceForText(_ text: String) -> AVSpeechSynthesisVoice? {
        guard autoVoiceSwitch, !languageVoices.isEmpty else { return nil }
        let lang = LanguageRouter().detect(text)
        return languageVoices[lang]
    }

    // MARK: 播放控制

    func playSegments(_ segments: [SpeechSegment], startIndex: Int = 0, cloud: Bool = false) {
        self.segments = segments
        self.mode = .segments
        self.useCloud = cloud
        currentIndex = max(0, min(startIndex, segments.count - 1))
        isPlaying = true
        speakCurrent()
    }

    func playPlain(_ chunks: [String], startIndex: Int = 0, cloud: Bool = false) {
        self.plainChunks = chunks
        self.mode = .plain
        self.useCloud = cloud
        currentIndex = max(0, min(startIndex, chunks.count - 1))
        isPlaying = true
        speakCurrent()
    }

    func pause() {
        if useCloud { audioPlayer?.pause() } else { synth.pauseSpeaking(at: .word) }
        isPlaying = false
    }

    func resume() {
        if useCloud { audioPlayer?.play() } else { synth.continueSpeaking() }
        isPlaying = true
    }

    func stop() {
        if useCloud { audioPlayer?.stop() } else { synth.stopSpeaking(at: .immediate) }
        audioPlayer = nil
        isPlaying = false
        currentIndex = 0
        currentSegmentIndex = -1
        nowSpeakingText = nil
    }

    private func finish() {
        isPlaying = false
        currentSegmentIndex = -1
        nowSpeakingText = nil
    }

    private func currentText() -> String? {
        switch mode {
        case .segments: return currentIndex < segments.count ? segments[currentIndex].text : nil
        case .plain: return currentIndex < plainChunks.count ? plainChunks[currentIndex] : nil
        }
    }

    private func speakCurrent() {
        guard let text = currentText() else { finish(); return }
        currentSegmentIndex = currentIndex
        nowSpeakingText = text
        onIndexChange?(currentIndex, mode == .segments)

        if useCloud {
            speakCloud(text)
        } else {
            speakLocal(text)
        }
    }

    /// 本地合成（AVSpeechSynthesizer）。显示语速 × rateScale 换算为内部标度。
    private func speakLocal(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        let internalRate = rate * Self.rateScale
        switch mode {
        case .segments:
            let seg = segments[currentIndex]
            if let id = seg.characterId, let v = roleVoices[id] {
                utterance.voice = v
            } else {
                utterance.voice = voiceForText(seg.text) ?? defaultVoice
            }
            let prosody = seg.emotion.prosody(baseRate: internalRate)
            utterance.rate = prosody.rate
            utterance.pitchMultiplier = prosody.pitch
            utterance.volume = prosody.volume
        case .plain:
            utterance.voice = voiceForText(text) ?? defaultVoice
            utterance.rate = internalRate
        }
        synth.speak(utterance)
    }

    /// 云端合成（AVAudioPlayer 播放）；失败自动回退本地并通知 UI。
    private func speakCloud(_ text: String) {
        Task {
            let data = await cloudProvider?(text)
            guard let data, data.count > 0, isPlaying, currentText() == text else {
                // 云端失败 → 本次段回退本地合成（并提示用户）
                if isPlaying {
                    onCloudFallback?()
                    speakLocal(text)
                }
                return
            }
            do {
                let p = try AVAudioPlayer(data: data)
                p.delegate = self
                audioPlayer = p
                p.play()
            } catch {
                onCloudFallback?()
                speakLocal(text)
            }
        }
    }

    private func advance() {
        // 停止后仍可能收到上一次朗读的完成回调，此时不得推进下一段（否则表现为「停了又继续读」）
        guard isPlaying else { return }
        currentIndex += 1
        speakCurrent()
    }
}

extension TTSPlayer: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in advance() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       willSpeakRangeOfSpeechString characterRange: NSRange,
                                       utterance: AVSpeechUtterance) {
        // 当前句内高亮由 UI 基于 currentSegmentIndex 处理，这里仅占位。
    }
}

extension TTSPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in advance() }
    }
}
