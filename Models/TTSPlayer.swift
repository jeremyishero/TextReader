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
    @Published var rate: Float = 0.5
    @Published var currentSegmentIndex: Int = -1

    /// 每读到一个新段/分块回调一次（供 ReadingView 保存进度）
    var onIndexChange: ((Int, Bool) -> Void)?   // (index, isAnalyzedMode)

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
        if useCloud { audioPlayer?.pause() } else { synth.pauseSpeaking(at: .wordBoundary) }
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
    }

    private func finish() {
        isPlaying = false
        currentSegmentIndex = -1
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
        onIndexChange?(currentIndex, mode == .segments)

        if useCloud {
            speakCloud(text)
        } else {
            speakLocal(text)
        }
    }

    /// 本地合成（AVSpeechSynthesizer）
    private func speakLocal(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        switch mode {
        case .segments:
            let seg = segments[currentIndex]
            if let id = seg.characterId, let v = roleVoices[id] {
                utterance.voice = v
            } else {
                utterance.voice = voiceForText(seg.text) ?? defaultVoice
            }
            let prosody = seg.emotion.prosody(baseRate: rate)
            utterance.rate = prosody.rate
            utterance.pitchMultiplier = prosody.pitch
            utterance.volume = prosody.volume
        case .plain:
            utterance.voice = voiceForText(text) ?? defaultVoice
            utterance.rate = rate
        }
        synth.speak(utterance)
    }

    /// 云端合成（AVAudioPlayer 播放）；失败自动回退本地。
    private func speakCloud(_ text: String) {
        Task {
            let data = await cloudProvider?(text)
            guard let data, data.count > 0, isPlaying, currentText() == text else {
                // 云端失败 → 本次段回退本地合成
                if isPlaying { speakLocal(text) }
                return
            }
            do {
                let p = try AVAudioPlayer(data: data)
                p.delegate = self
                audioPlayer = p
                p.play()
            } catch {
                speakLocal(text)
            }
        }
    }

    private func advance() {
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
