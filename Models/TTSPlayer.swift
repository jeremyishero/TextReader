import Foundation
import AVFoundation
import CoreLogic
import MediaPlayer

/// 声音预听器：独立于播放器的合成器实例，用于「选定前先试听这个声音」。
/// 全局共享单例，避免与朗读播放互相打断。
@MainActor
final class VoicePreviewer: ObservableObject {
    static let shared = VoicePreviewer()
    private let synth = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?

    /// 用指定声音说一句「你好，我是中国人」。voice 传 nil 时用简体中文默认声。
    func preview(_ voice: AVSpeechSynthesisVoice?, rate: Float = 1.0, pitch: Float = 1.0) {
        synth.stopSpeaking(at: .immediate)
        audioPlayer?.stop()
        let utterance = AVSpeechUtterance(string: "你好，我是中国人")
        if let voice {
            utterance.voice = voice
        } else if let fallback = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.language == "zh-CN" }) {
            utterance.voice = fallback
        }
        utterance.rate = min(max(rate * TTSPlayer.rateScale, 0.0), 1.0)
        utterance.pitchMultiplier = min(max(pitch, 0.5), 2.0)
        utterance.volume = 1.0
        synth.speak(utterance)
    }

    /// 播放已合成的音频数据（离线语音包试听用）。
    func playAudio(_ data: Data) {
        synth.stopSpeaking(at: .immediate)
        audioPlayer = try? AVAudioPlayer(data: data)
        audioPlayer?.play()
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        audioPlayer?.stop()
    }
}

/// 自定义朗读规则（每文档最多 20 条）：朗读前把「匹配文本」替换为「替换文本」。
/// 例：匹配「……」替换为「……无语」→ 人物说话出现省略号时会多读一句「无语」。
struct CustomRule: Codable, Identifiable, Equatable {
    var find: String
    var replace: String
    var id: String { find }
}

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
    /// 每角色音高补偿（性别音高补偿/手动微调），默认 1.0
    private var rolePitches: [String: Float] = [:]
    /// 每角色性别（离线语音包按性别路由音色用）
    private var roleGenders: [String: Gender] = [:]
    private var defaultVoice: AVSpeechSynthesisVoice?
    private var languageVoices: [ScriptLanguage: AVSpeechSynthesisVoice] = [:]
    var autoVoiceSwitch = true
    private var currentIndex = 0
    private var mode: PlayMode = .plain

    /// 合成优先级：离线语音包 → 云端 TTS → 本地 AVSpeech。
    /// offlineProvider/cloudProvider 由 ReadingView 按当前文档/设置注入，未启用时返回 nil 自动降级。
    var offlineProvider: ((String, Gender, String) async -> Data?)?
    var cloudProvider: ((String) async -> Data?)?
    private var audioPlayer: AVAudioPlayer?
    /// 当前段原始文本（未经规则替换），供异步合成完成后的归属校验
    private var speakingRawText: String?

    /// 自定义朗读规则（由 ReadingView 按文档注入；本地/云端朗读前统一应用）
    var customRules: [CustomRule] = []

    /// 依次应用自定义规则：匹配文本 → 替换文本
    private func applyCustomRules(_ text: String) -> String {
        guard !customRules.isEmpty else { return text }
        var out = text
        for rule in customRules where !rule.find.isEmpty {
            out = out.replacingOccurrences(of: rule.find, with: rule.replace)
        }
        return out
    }

    // 全局播放条共享状态（App 各界面共用同一个 player 实例）
    @Published var useAnalyzedPlayback: Bool = false   // 角色分声开关（阅读页与全局播放条共享）
    @Published var activeTitle: String? = nil           // 当前正在朗读的文档标题（播放条显示）
    /// 由 ReadingView 注入：从指定段索引开始朗读（nil = 从头）；全局播放条在尚无内容时调用它
    var startPlaybackHandler: ((Int?) -> Void)?
    /// 由 ReadingView 注入：打开章节目录
    var openTOCHandler: (() -> Void)?

    /// 是否已装载可播放内容（全局播放条据此显示 播放 / 继续 / 无内容）
    var isLoaded: Bool { !segments.isEmpty || !plainChunks.isEmpty }

    /// 全局播放条 / 锁屏控件请求开始朗读
    func requestStartPlayback(from index: Int? = nil) {
        startPlaybackHandler?(index)
    }

    private enum PlayMode { case plain, segments }

    override init() {
        super.init()
        synth.delegate = self
        setupRemoteCommands()
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
    func setRolePitches(_ map: [String: Float]) { rolePitches = map }
    func setRoleGenders(_ map: [String: Gender]) { roleGenders = map }
    func setDefaultVoice(_ v: AVSpeechSynthesisVoice?) { defaultVoice = v }
    func setLanguageVoices(_ map: [ScriptLanguage: AVSpeechSynthesisVoice]) { languageVoices = map }

    /// 按性别池 + 轮转为各角色分配声音与音高：
    /// - 声音池优先简体中文普通话（zh-CN），其次 zh-Hans，再退到 zh 系列，避免选到粤/台口音读出「洋腔洋调」；
    /// - 男角色从「男声池」取、女角色从「女声池」取、中性/未知从「中性池」取；
    /// - 同一性别的不同角色依次轮转池内不同声音（男 A / 男 B 声音不同）；
    /// - 按 role.id 分配一次，同一角色（含所有别名）全程固定同一声音；
    /// - **性别音高补偿**：若设备没有性别命名的声音素材（男声池/女声池为空），男角色音高 ×0.85、
    ///   女角色 ×1.12，保证男女听感有区分；池存在时音高 1.0 不干预。
    /// 声音性别依据系统声音名称中的 Male/Female/男/女 关键词（注意先判 Female 再判 Male）。
    static func assignVoicesAndPitches(roles: [CharacterRole]) -> (voices: [String: AVSpeechSynthesisVoice], pitches: [String: Float]) {
        let all = AVSpeechSynthesisVoice.speechVoices()
        var poolBase = all.filter { $0.language == "zh-CN" }
        if poolBase.isEmpty { poolBase = all.filter { $0.language.hasPrefix("zh-Hans") } }
        if poolBase.isEmpty { poolBase = all.filter { $0.language.hasPrefix("zh") } }
        if poolBase.isEmpty { poolBase = all }

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
        let hadMalePool = !malePool.isEmpty
        let hadFemalePool = !femalePool.isEmpty
        if malePool.isEmpty { malePool = Array((neutralPool + femalePool).prefix(2)) }
        if femalePool.isEmpty { femalePool = Array((neutralPool + malePool).prefix(2)) }
        if neutralPool.isEmpty { neutralPool = poolBase }

        var voices: [String: AVSpeechSynthesisVoice] = [:]
        var pitches: [String: Float] = [:]
        var mi = 0, fi = 0, ni = 0
        for role in roles {
            let pitch: Float
            switch role.gender {
            case .male:
                if !malePool.isEmpty {
                    voices[role.id] = malePool[mi % malePool.count]; mi += 1
                }
                pitch = hadMalePool ? 1.0 : 0.80   // 无男声素材 → 低音高补偿
            case .female:
                if !femalePool.isEmpty {
                    voices[role.id] = femalePool[fi % femalePool.count]; fi += 1
                }
                pitch = hadFemalePool ? 1.0 : 1.18 // 无女声素材 → 高音高补偿
            case .neutral:
                if !neutralPool.isEmpty {
                    voices[role.id] = neutralPool[ni % neutralPool.count]; ni += 1
                }
                pitch = 1.0
            }
            pitches[role.id] = pitch
        }
        // 补漏（池被借空等极端情况）
        for role in roles where voices[role.id] == nil {
            if !poolBase.isEmpty {
                voices[role.id] = poolBase[abs(role.id.hashValue) % poolBase.count]
            }
        }
        return (voices, pitches)
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
        currentIndex = max(0, min(startIndex, segments.count - 1))
        isPlaying = true
        updateNowPlaying()
        speakCurrent()
    }

    func playPlain(_ chunks: [String], startIndex: Int = 0, cloud: Bool = false) {
        self.plainChunks = chunks
        self.mode = .plain
        currentIndex = max(0, min(startIndex, chunks.count - 1))
        isPlaying = true
        updateNowPlaying()
        speakCurrent()
    }

    func pause() {
        audioPlayer?.pause()
        synth.pauseSpeaking(at: .word)
        isPlaying = false
        updateNowPlaying()
    }

    func resume() {
        audioPlayer?.play()
        synth.continueSpeaking()
        isPlaying = true
        updateNowPlaying()
    }

    /// 快退/快进（秒）。离线/云端音频路径精确按时间跳转；系统 TTS 没有时间轴，按「段」近似。
    /// - 离线/云端：AVAudioPlayer 直接改 currentTime（±seconds，并限制在 0~duration）。
    /// - 系统 AVSpeechSynthesizer：后退=从当前段开头重读（≈回到上一句），前进=跳到下一段。
    func seek(by seconds: TimeInterval) {
        if let ap = audioPlayer, ap.duration > 0 {
            ap.currentTime = min(max(ap.currentTime + seconds, 0), ap.duration)
            updateNowPlaying()
            return
        }
        guard isPlaying else { return }
        // 系统 TTS 无时间轴：先停掉当前朗读（isPlaying 置 false，确保 stopSpeaking 即便触发
        // didFinish→advance 也不会重复推进），再从目标段重新开始，避免旧朗读排队/跳两段。
        isPlaying = false
        audioPlayer?.stop()
        synth.stopSpeaking(at: .immediate)
        let total = (mode == .segments ? segments.count : plainChunks.count)
        let target = seconds < 0 ? currentIndex : currentIndex + 1
        guard target < total else { stop(); return }
        currentIndex = target
        isPlaying = true
        speakCurrent()
        updateNowPlaying()
    }

    func stop() {
        audioPlayer?.stop()
        synth.stopSpeaking(at: .immediate)
        audioPlayer = nil
        isPlaying = false
        currentIndex = 0
        currentSegmentIndex = -1
        nowSpeakingText = nil
        speakingRawText = nil
        updateNowPlaying()
    }

    private func finish() {
        isPlaying = false
        currentSegmentIndex = -1
        nowSpeakingText = nil
    }

    // MARK: 锁屏 / 后台（最小化）媒体控制

    /// 注册锁屏 / 控制中心 / 灵动岛的媒体控制：最小化 App 后仍显示「正在播放」小窗并可控制。
    private func setupRemoteCommands() {
        let rc = MPRemoteCommandCenter.shared()
        rc.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.remoteResume() }
            return .success
        }
        rc.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        rc.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.remoteToggle() }
            return .success
        }
        rc.skipBackwardCommand.preferredIntervals = [5.0]
        rc.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.seek(by: -5) }
            return .success
        }
        rc.skipForwardCommand.preferredIntervals = [5.0]
        rc.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.seek(by: 5) }
            return .success
        }
        rc.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.seek(by: -5) }
            return .success
        }
        rc.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.seek(by: 5) }
            return .success
        }
    }

    private func remoteResume() {
        if isLoaded { resume() } else { requestStartPlayback() }
    }
    private func remoteToggle() {
        if isPlaying { pause() }
        else if isLoaded { resume() }
        else { requestStartPlayback() }
    }

    /// 刷新锁屏「正在播放」信息（标题 + 进度 + 速率）。
    private func updateNowPlaying() {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = activeTitle ?? "朗读"
        info[MPMediaItemPropertyArtist] = "TextReader"
        if let ap = audioPlayer, ap.duration > 0 {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = ap.currentTime
            info[MPMediaItemPropertyPlaybackDuration] = ap.duration
        }
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func currentText() -> String? {
        switch mode {
        case .segments: return currentIndex < segments.count ? segments[currentIndex].text : nil
        case .plain: return currentIndex < plainChunks.count ? plainChunks[currentIndex] : nil
        }
    }

    private func speakCurrent() {
        guard let raw = currentText() else { finish(); return }
        let text = applyCustomRules(raw)
        currentSegmentIndex = currentIndex
        speakingRawText = raw
        nowSpeakingText = text
        onIndexChange?(currentIndex, mode == .segments)

        Task { @MainActor in
            // 合成优先级：离线语音包 → 云端 TTS → 本地 AVSpeech
            let segId = segments.indices.contains(currentIndex) ? (segments[currentIndex].characterId ?? "") : ""
            let segGender = roleGenders[segId] ?? .neutral
            if let offlineProvider, let data = await offlineProvider(text, segGender, segId), isPlaying, speakingRawText == raw {
                playAudioData(data, fallbackText: text, notice: "离线语音包合成失败，已回退")
                return
            }
            if let cloudProvider, let data = await cloudProvider(text), isPlaying, speakingRawText == raw {
                playAudioData(data, fallbackText: text, notice: nil)
                return
            }
            guard isPlaying, speakingRawText == raw else { return }
            speakLocal(text)
        }
    }

    /// 用内存中的音频数据（WAV/MP3 等）播放本段。
    private func playAudioData(_ data: Data, fallbackText: String, notice: String?) {
        do {
            let p = try AVAudioPlayer(data: data)
            p.delegate = self
            audioPlayer = p
            p.play()
        } catch {
            if let notice { onCloudFallback?() }
            speakLocal(fallbackText)
        }
    }

    /// 本地合成（AVSpeechSynthesizer）。显示语速 × rateScale 换算为内部标度。
    /// 块尾带 "\n"（TextChunker 段落标记）→ 修剪并在读完后插入明显停顿，实现「按段停顿」。
    private func speakLocal(_ text: String) {
        var content = text
        var postDelay: TimeInterval = 0.06
        if content.hasSuffix(TextChunker.paragraphBreakMarker) {
            content.removeLast()
            postDelay = 0.45
        }
        let utterance = AVSpeechUtterance(string: content)
        utterance.postUtteranceDelay = postDelay
        let internalRate = rate * Self.rateScale
        // 音量统一为最大：不同系统声音本身响度不同，情绪音量浮动会造成「一时大一时小」，全部固定 1.0
        utterance.volume = 1.0
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
            // 音高 = 情绪音高 × 角色音高补偿（性别区分），限制在引擎允许范围
            let rolePitch = rolePitches[seg.characterId ?? ""] ?? 1.0
            utterance.pitchMultiplier = min(max(prosody.pitch * rolePitch, 0.5), 2.0)
        case .plain:
            utterance.voice = voiceForText(text) ?? defaultVoice
            utterance.rate = internalRate
        }
        synth.speak(utterance)
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
