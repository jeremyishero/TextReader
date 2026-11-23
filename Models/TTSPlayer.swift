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
        } else if let fallback = TTSPlayer.keepTingting(AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "zh-CN" }).first {
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

/// 自定义朗读规则（每文档最多 20 条）：
/// - replace：朗读前把「匹配文本」替换为「替换文本」（例：「……」→「……无语」）；
/// - skip：把「匹配文本」整体忽略/跳过（不朗读），如特殊符号、乱码、广告水印等。
/// 例：匹配「……」替换为「……无语」→ 人物说话出现省略号时会多读一句「无语」。
struct CustomRule: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case replace, skip }
    var kind: Kind
    var find: String
    var replace: String
    var id: String { kind.rawValue + "|" + find }

    init(kind: Kind = .replace, find: String, replace: String) {
        self.kind = kind
        self.find = find
        self.replace = replace
    }

    // 旧配置（< 每文档 rules.json）没有 kind 字段 → 补默认 .replace，避免反序列化失败
    private enum CodingKeys: String, CodingKey { case kind, find, replace }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .replace
        find = try c.decode(String.self, forKey: .find)
        replace = try c.decode(String.self, forKey: .replace)
    }
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
    /// 记录中断发生前是否在朗读：只有中断前在朗读、且系统建议恢复时才续读，
    /// 避免「退后台停、重进 App 又莫名自动朗读」。
    private var wasPlayingBeforeInterrupt = false
    /// 语速（显示标度）：1.0 = 正常人语速，范围 0.5–3.0。
    /// 内部朗读时乘以 rateScale 换算为 AVSpeechUtterance 标度（其 0.5 = 正常语速）。
    @Published var rate: Float = 1.0
    /// 段落间停顿（秒）：段末带 TextChunker.paragraphBreakMarker 时使用；默认 0（不停顿）。
    /// 由 ReadingView 按设置页「段落间停顿」注入，改动后下次起播生效。
    var paragraphPause: TimeInterval = 0
    /// 章节间停顿（秒）：当前段以「第X章/回/卷」开头时，取 max(段落停顿, 章节停顿)；默认 0。
    var chapterPause: TimeInterval = 0
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

    // MARK: 预取流水线（消除「解析一段读一段」的卡顿）
    /// 已就绪的待播单元：离线/云端 TTS 为合成好的音频 Data；系统 AVSpeech 为预构建的 AVSpeechUtterance。
    /// 播放到第 k 段时，其后的段已在后台并行合成/构建好，从而朗读连续、不再逐段卡顿。
    private enum PreparedUnit {
        case audio(Data, fallback: String, notice: String?)
        case utterance(AVSpeechUtterance)
    }
    /// 已准备好的单元（索引 → 单元）。轮到该段时直接消费，无需现场等待合成。
    private var prepared: [Int: PreparedUnit] = [:]
    /// 进行中的预取任务（索引 → Task）。
    private var prepTasks: [Int: Task<PreparedUnit?, Never>] = [:]
    /// 预取窗口：当前段播放时预合成其后多少段。
    /// 引擎是串行的，预取过多会让队列堆积、当前段排长队（曾经 depth=4 导致段间 8 秒停顿）。
    /// 取 2：既让合成与朗读重叠，又不让队列堵住下一段。
    private let prefetchDepth = 2

    /// 合成优先级：离线语音包 → 云端 TTS → 本地 AVSpeech。
    /// offlineProvider/cloudProvider 由 ReadingView 按当前文档/设置注入，未启用时返回 nil 自动降级。
    var offlineProvider: ((String, Gender, String) async -> Data?)?
    var cloudProvider: ((String) async -> Data?)?

    /// 角色面板手工指定的离线包：characterId → (packId, sid)。命中时绕过性别池自动分配。
    var manualOfflinePacks: [String: (packId: String, sid: Int32)] = [:]
    /// 角色面板手工指定了「系统声」的角色：跳过离线/云端合成，强制走 AVSpeech 的 roleVoices，
    /// 否则离线（优先级更高）会无声覆盖用户的选择。
    var manualSystemVoiceIds: Set<String> = []
    /// 手工离线包的合成通道。刻意做成「只收值类型参数」的非隔离闭包：
    /// 闭包体不得捕获 player/settings 等 @MainActor 对象，否则会从播放热路径跨 actor 同步读取，
    /// 导致预取任务挂起、整段朗读无声。由 ReadingView 在 configurePlayer 里注入。
    var manualOfflineSynth: ((String, String, Int32, Float) async -> Data?)?
    private var audioPlayer: AVAudioPlayer?
    /// 当前段原始文本（未经规则替换），供异步合成完成后的归属校验
    private var speakingRawText: String?

    /// 自定义朗读规则（由 ReadingView 按文档注入；本地/云端朗读前统一应用）
    var customRules: [CustomRule] = []

    /// 依次应用自定义规则：替换类按「匹配 → 替换」，跳过类把匹配内容整体移除。
    private func applyCustomRules(_ text: String) -> String {
        guard !customRules.isEmpty else { return text }
        var out = text
        for rule in customRules where !rule.find.isEmpty {
            switch rule.kind {
            case .replace:
                out = out.replacingOccurrences(of: rule.find, with: rule.replace)
            case .skip:
                out = out.replacingOccurrences(of: rule.find, with: "")
            }
        }
        return out
    }

    // 全局播放条共享状态（App 各界面共用同一个 player 实例）
    @Published var useAnalyzedPlayback: Bool = false   // 角色分声开关（阅读页与全局播放条共享）
    @Published var activeTitle: String? = nil           // 当前正在朗读的文档标题（播放条显示）
    /// 当前已装载/正在朗读的文档 id（UUID 字符串）；nil 表示没有任何书装载。
    /// 用于判断「正在播放的是不是当前这本书」，从而决定阅读页底部控制条只显示「播放本书」还是完整控制。
    @Published var currentDocumentId: String? = nil
    /// 当前正在显示的阅读页所属文档 id（由 ReadingView 在 onAppear/onDisappear 维护）；
    /// nil 表示当前不在任何阅读页（如主界面/文档列表）。
    @Published var readingViewBookId: String? = nil
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
        // 音频会话被打断（来电/其他 App 抢音频/锁屏）后恢复朗读：
        // 之前没有任何 interruption 监听，中断结束后会话停在非激活态，朗读再也不出声，
        // 表现为「读一会儿自动停/看着像 App 退出了」。
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            Task { @MainActor in
                switch type {
                case .began:
                    AppLogger.log("audio interruption BEGAN isPlaying=\(self.isPlaying)")
                    self.wasPlayingBeforeInterrupt = self.isPlaying
                    // 中断期间暂停发声但不改 isPlaying（保持“逻辑上在播放”的状态，锁屏控件仍显示播放）
                    self.synth.pauseSpeaking(at: .word)
                    self.audioPlayer?.pause()
                case .ended:
                    AppLogger.log("audio interruption ENDED wasPlaying=\(self.wasPlayingBeforeInterrupt)")
                    let optRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                    let opts = AVAudioSession.InterruptionOptions(rawValue: optRaw)
                    try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
                    // 只有「中断前确实在朗读」才恢复：避免进后台被系统暂停后、重进 App 又自动读起来
                    if self.wasPlayingBeforeInterrupt && opts.contains(.shouldResume) {
                        self.audioPlayer?.play()
                        self.synth.continueSpeaking()
                    } else if self.wasPlayingBeforeInterrupt {
                        // 系统未建议恢复：用 resume() 走完整恢复路径（含预取重启）
                        self.resume()
                    }
                    self.wasPlayingBeforeInterrupt = false
                @unknown default: break
                }
            }
        }
    }

    // MARK: 声音配置

    /// 简体中文（zh-CN）系统声白名单：只放行 Tingting。
    /// 其余 zh-CN 系统声念中文口音生硬（用户明确要求全部去掉）；其它语言不受限。
    static func isAllowedSystemVoice(_ v: AVSpeechSynthesisVoice) -> Bool {
        if v.language.hasPrefix("zh-CN") { return v.name.lowercased().contains("tingting") }
        return true
    }

    /// 从列表中只保留 Tingting；若设备上没有 Tingting 则原样返回（防呆：不致无中文声可选）。
    /// 对非 zh-CN 列表（繁体/英文）无影响，原样通过。
    static func keepTingting(_ voices: [AVSpeechSynthesisVoice]) -> [AVSpeechSynthesisVoice] {
        let tt = voices.filter { isAllowedSystemVoice($0) }
        return tt.isEmpty ? voices : tt
    }

    /// 按语言与性别挑选离线语音（AVSpeechSynthesisVoice 不直接暴露性别，用名称关键词兜底）。
    static func pickVoice(language: String = "zh-CN", preferGender: Gender? = nil) -> AVSpeechSynthesisVoice? {
        let voices = keepTingting(AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(language) })
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
        // 白名单：zh-CN 只保留 Tingting，其余念中文别扭的系统声不进分配池；
        // 池内只剩 Tingting 时按既有设计走「性别音高补偿」（男 0.80 / 女 1.18）区分角色。
        var poolBase = keepTingting(all.filter { $0.language == "zh-CN" })
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
        // 不重复分配：按角色顺序依次占用池内不同音色；池用尽后回退该性别默认声，
        // 并用递增音高偏移区分，避免大量角色听起来完全一样。
        func assignPool(_ pool: [AVSpeechSynthesisVoice], genderPitch: Float,
                        roles: [CharacterRole], used: inout Set<String>) {
            var cursor = 0
            for role in roles {
                if cursor < pool.count {
                    let v = pool[cursor]; cursor += 1
                    voices[role.id] = v; pitches[role.id] = genderPitch
                    used.insert(v.identifier)
                } else {
                    // 声音资源用完 → 系统默认声 + 音高递增区分（0.86 ~ 1.22）
                    let fallback = pool.first ?? poolBase.first
                    voices[role.id] = fallback
                    let steps = cursor - pool.count
                    pitches[role.id] = genderPitch * (0.86 + Float(steps % 5) * 0.09)
                    cursor += 1
                }
            }
        }
        var used = Set<String>()
        assignPool(malePool,   genderPitch: hadMalePool ? 1.0 : 0.80,
                   roles: roles.filter { $0.gender == .male || $0.gender == .eunuch }, used: &used)
        assignPool(femalePool, genderPitch: hadFemalePool ? 1.0 : 1.18,
                   roles: roles.filter { $0.gender == .female }, used: &used)
        assignPool(neutralPool, genderPitch: 1.0,
                   roles: roles.filter { $0.gender == .neutral }, used: &used)
        // 补漏（极端：完全没有池）
        for role in roles where voices[role.id] == nil {
            if let any = poolBase.first { voices[role.id] = any; pitches[role.id] = 1.0 }
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
        AppLogger.log("playSegments count=\(segments.count) start=\(startIndex) cloud=\(cloud)")
        // 切章/重新起播：必须先掐断上一次的朗读，否则旧 synth utterance / 离线 audioPlayer
        // 会继续读出声，和新内容重叠——用户所见「旧音继续读半天才切/读完才停」。
        // 先把 isPlaying 置 false，避免 stopSpeaking 触发的 didFinish→advance 误推进。
        isPlaying = false
        audioPlayer?.stop()
        audioPlayer = nil
        synth.stopSpeaking(at: .immediate)
        resetPipeline()
        self.segments = segments
        self.mode = .segments
        currentIndex = max(0, min(startIndex, segments.count - 1))
        isPlaying = true
        updateNowPlaying()
        speakCurrent()
    }

    func playPlain(_ chunks: [String], startIndex: Int = 0, cloud: Bool = false) {
        AppLogger.log("playPlain count=\(chunks.count) start=\(startIndex) cloud=\(cloud)")
        // 同 playSegments：先掐断旧朗读，防止串音/旧音继续。
        isPlaying = false
        audioPlayer?.stop()
        audioPlayer = nil
        synth.stopSpeaking(at: .immediate)
        resetPipeline()
        self.plainChunks = chunks
        self.mode = .plain
        currentIndex = max(0, min(startIndex, chunks.count - 1))
        isPlaying = true
        updateNowPlaying()
        speakCurrent()
    }

    func pause() {
        AppLogger.log("pause called")
        audioPlayer?.pause()
        synth.pauseSpeaking(at: .word)
        isPlaying = false
        updateNowPlaying()
    }

    func resume() {
        AppLogger.log("resume called")
        audioPlayer?.play()
        synth.continueSpeaking()
        isPlaying = true
        updateNowPlaying()
        prefetch(from: currentIndex + 1)
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
        resetPipeline()
        let total = (mode == .segments ? segments.count : plainChunks.count)
        let target = seconds < 0 ? currentIndex : currentIndex + 1
        guard target < total else { stop(); return }
        currentIndex = target
        isPlaying = true
        speakCurrent()
        updateNowPlaying()
    }

    func stop() {
        AppLogger.log("stop called (isPlaying=\(isPlaying) idx=\(currentIndex))")
        resetPipeline()
        audioPlayer?.stop()
        synth.stopSpeaking(at: .immediate)
        audioPlayer = nil
        currentDocumentId = nil   // 停止即结束本次播放会话，当前书标记清空
        isPlaying = false
        // 清空已装载内容：停止即结束本次播放会话，让 isLoaded 归 false。
        // 否则播放条会显示「继续」并走 resume()，而此时已无内容可续（既不会重播、也跳不到断点）。
        // 清空后按钮变「播放」，经 requestStartPlayback(from:nil) 由 ReadingView 按保存进度重新起播。
        segments = []
        plainChunks = []
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
        let idx = currentIndex
        guard let raw = currentText() else { finish(); return }
        // 已预取好：直接消费，零等待；否则按需准备（后台合成/构建），准备完再播。
        if let p = prepared.removeValue(forKey: idx) {
            consumePrepared(p, raw: raw, idx: idx)
            prefetch(from: idx + 1)
            return
        }
        // 预取未就绪：给当前段一次有界等待，优先拿到离线音色。
        // 关键：此刻不预取后续段，让当前段独占串行引擎（旧实现同时预取 4 段把队列塞满，
        // 当前段排队尾等满 8 秒超时——用户实测段间 8 秒停顿的根因）。
        // 等当前段开始播放后，再在播放期间预取后续段，合成与朗读重叠进行。
        let task = prepTask(for: idx)
        let gen = pipelineGeneration
        Task { @MainActor in
            let ready = await Self.withTimeout(seconds: Self.currentSegmentWait) { await task.value }
            // 切章/stop 后本等待者已过期：新流程已接管，静默退出（并记日志便于诊断）。
            guard self.pipelineGeneration == gen else {
                AppLogger.log("speakCurrent idx=\(idx) 等待被切章/stop作废 gen=\(gen)→\(self.pipelineGeneration)")
                return
            }
            guard self.isPlaying, self.currentIndex == idx else {
                AppLogger.log("speakCurrent idx=\(idx) 状态不符 isPlaying=\(self.isPlaying) cur=\(self.currentIndex) → 强制开播本段")
                // 不再静默 return：状态偶发不一致时也要把本段读出来，否则无 speak→无 didFinish→永久停。
                self.forceSpeakSystem(raw: raw, idx: idx)
                return
            }
            if let p = ready {
                self.consumePrepared(p, raw: raw, idx: idx)
            } else {
                self.forceSpeakSystem(raw: raw, idx: idx)
            }
            // 当前段已开播：此刻才预取后续段，与朗读重叠，不阻塞当前段
            self.prefetch(from: idx + 1)
        }
    }

    /// 强制用系统声朗读本段（等待超时 / 状态不一致的兜底），确保一定有 speak 推进流水线。
    private func forceSpeakSystem(raw: String, idx: Int) {
        AppLogger.log("speakCurrent idx=\(idx) 等待\(Self.currentSegmentWait)s未就绪 → 系统声兜底")
        currentSegmentIndex = idx
        speakingRawText = raw
        nowSpeakingText = raw
        onIndexChange?(idx, mode == .segments)
        updateNowPlaying()
        synth.speak(buildUtterance(for: idx, text: raw))
    }

    /// 当前段等待离线合成的上限（秒）。用户要求段间停顿 <1s，取 0.6s。
    /// 离线合成若在 0.6s 内没好就系统声兜底——换取流畅；稳态下预取命中的段仍用离线音色。
    private static let currentSegmentWait: Double = 0.6

    /// 给异步任务加超时：超时立即返回 nil，不等待原任务（原任务后台继续但不阻塞朗读）。
    /// 注意：不能用 withTaskGroup——它的 body 结束时会等待所有子任务，超时里 cancelAll 对
    /// 不响应取消的 engineQueue 合成无效，导致「8秒超时」形同虚设、引擎卡住仍永久无声。
    private static func withTimeout<T>(seconds: Double,
                                       operation: @escaping () async -> T?) async -> T? {
        await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            let lock = NSLock()
            var finished = false
            func deliver(_ value: T?) {
                lock.lock()
                if finished { lock.unlock(); return }
                finished = true
                lock.unlock()
                cont.resume(returning: value)
            }
            // 真正的合成任务
            Task {
                let v = await operation()
                deliver(v)
            }
            // 超时竞速：先到者胜
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                deliver(nil)
            }
        }
    }

    // MARK: 预取流水线实现

    /// 当前总段数（取决于模式）。
    private func totalCount() -> Int {
        mode == .segments ? segments.count : plainChunks.count
    }

    /// 流水线代次：每次 stop / 切章 / 重新起播 +1。
    /// 旧的预取 Task 无法被真正取消（串行 engineQueue 里的 C 层合成为响应 cancel），
    /// 用 generation 让它们完成时识别「我已过期」，不写回 prepared、不误删新章节的任务——
    /// 否则切章后旧音频会污染新章节，或旧 Task 的 defer 把新 Task 从 prepTasks 里删掉，
    /// 导致新章节等待一个已取消的 Task、永久无声。
    private var pipelineGeneration: Int = 0

    /// 取消所有预取任务并清空缓冲（停止 / 跳转 / 重新开始时调用）。
    private func resetPipeline() {
        pipelineGeneration += 1
        for (_, t) in prepTasks { t.cancel() }
        prepTasks.removeAll()
        prepared.removeAll()
    }

    /// 声音配置变更后调用：丢掉「当前段之后」已缓存的预取音频，让后续段用新声音重建。
    /// 当前正在朗读的段不受影响（读完当前段后切换，符合用户预期）。
    func refreshVoiceForUpcoming() {
        let keep = currentIndex
        for (idx, t) in prepTasks where idx > keep { t.cancel() }
        prepTasks = prepTasks.filter { $0.key <= keep }
        prepared = prepared.filter { $0.key <= keep }
        if isPlaying { prefetch(from: currentIndex + 1) }
    }

    /// 取（或创建）某个索引的预取任务；任务完成会把单元写入 prepared 缓存。
    private func prepTask(for idx: Int) -> Task<PreparedUnit?, Never> {
        if let t = prepTasks[idx] { return t }
        let gen = pipelineGeneration
        let t = Task { @MainActor () async -> PreparedUnit? in
            guard idx >= 0 else { return nil }
            let unit = await self.buildPrepared(idx)
            // 代次变了（stop/切章）：旧结果作废，不写回、不动当前 prepTasks
            guard self.pipelineGeneration == gen else { return nil }
            self.prepTasks.removeValue(forKey: idx)
            if let u = unit { self.prepared[idx] = u }
            return unit
        }
        prepTasks[idx] = t
        return t
    }

    /// 预合成/预构建 [from, from+prefetchDepth) 的后续段（并发）。已就绪或在途的跳过。
    /// 同时释放窗口之前的已播放缓冲，避免内存无限增长。
    private func prefetch(from start: Int) {
        let total = totalCount()
        guard isPlaying, start < total else { return }
        let end = min(start + prefetchDepth, total)
        for i in start..<end {
            if prepared[i] == nil && prepTasks[i] == nil {
                prepTasks[i] = prepTask(for: i)
            }
        }
        let keepFrom = max(0, start - 1)
        let toRemove = prepared.keys.filter { $0 < keepFrom }
        for k in toRemove { prepared.removeValue(forKey: k) }
    }

    /// 构建某索引的待播单元：离线语音包 → 云端 TTS → 系统 AVSpeech（依次回退）。
    /// 离线/云端合成在引擎/网络线程进行，不阻塞主线程；多个预取任务并行推进，
    /// 形成「四个进程交替解析朗读」的效果，消除逐段等待的卡顿。
    private func buildPrepared(_ idx: Int) async -> PreparedUnit? {
        let text: String
        let segId: String
        let gender: Gender
        switch mode {
        case .segments:
            guard segments.indices.contains(idx) else { return nil }
            text = segments[idx].text
            segId = segments[idx].characterId ?? ""
            gender = roleGenders[segId] ?? .neutral
        case .plain:
            guard plainChunks.indices.contains(idx) else { return nil }
            text = plainChunks[idx]
            segId = ""
            gender = .neutral
        }
        let processed = applyCustomRules(text)
        // 手工指定「系统声」的角色：跳过离线/云端，让 roleVoices 真正生效
        if !segId.isEmpty, manualSystemVoiceIds.contains(segId) {
            return .utterance(buildUtterance(for: idx, text: processed))
        }
        // 手工指定离线包：在 @MainActor 上下文读取映射，合成闭包只接收值类型参数，
        // 避免 offlineProvider 闭包跨 actor 读取播放器状态造成预取任务挂起。
        if !segId.isEmpty, let manual = manualOfflinePacks[segId],
           let synth = manualOfflineSynth,
           let data = await synth(processed, manual.packId, manual.sid, rate) {
            return .audio(data, fallback: processed, notice: nil)
        }
        if let offlineProvider, let data = await offlineProvider(processed, gender, segId) {
            return .audio(data, fallback: processed, notice: "离线语音包合成失败，已回退")
        }
        if let cloudProvider, let data = await cloudProvider(processed) {
            return .audio(data, fallback: processed, notice: nil)
        }
        return .utterance(buildUtterance(for: idx, text: processed))
    }

    /// 消费一个已准备好的单元（设置高亮/进度并播放）。
    private func consumePrepared(_ unit: PreparedUnit, raw: String, idx: Int) {
        currentSegmentIndex = idx
        speakingRawText = raw
        nowSpeakingText = raw
        onIndexChange?(idx, mode == .segments)
        updateNowPlaying()
        switch unit {
        case .audio(let data, let fallback, let notice):
            playAudioData(data, fallbackText: fallback, notice: notice)
        case .utterance(let u):
            synth.speak(u)
        }
    }

    /// 预构建系统 TTS 的 AVSpeechUtterance（与 speakLocal 一致，但按指定索引取角色/情绪），
    /// 以便预取段在播放前就完成构建，避免每段切换时的构建延迟。
    private func buildUtterance(for idx: Int, text: String) -> AVSpeechUtterance {
        var content = text
        var postDelay: TimeInterval = 0.06
        // 章节开头（第X章/回/卷）→ 章节间停顿；段落末尾标记 → 段落间停顿
        let isChapterStart = content.range(of: #"^\s*第[一二三四五六七八九十百千0-9]+[章回卷]"#,
                                           options: .regularExpression) != nil
        if content.hasSuffix(TextChunker.paragraphBreakMarker) {
            content.removeLast()
            postDelay = paragraphPause
        }
        if isChapterStart { postDelay = max(postDelay, chapterPause) }
        let utterance = AVSpeechUtterance(string: content)
        utterance.postUtteranceDelay = postDelay
        let internalRate = rate * Self.rateScale
        // 音量统一为最大：不同系统声音本身响度不同，情绪音量浮动会造成「一时大一时小」，全部固定 1.0
        utterance.volume = 1.0
        switch mode {
        case .segments:
            guard segments.indices.contains(idx) else {
                utterance.voice = voiceForText(text) ?? defaultVoice
                utterance.rate = internalRate
                return utterance
            }
            let seg = segments[idx]
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
        return utterance
    }

    /// 用内存中的音频数据（WAV/MP3 等）播放本段。
    private func playAudioData(_ data: Data, fallbackText: String, notice: String?) {
        // 前置校验：AVAudioPlayer(data:) 对畸形 WAV 可能抛「不可捕获的 NSException」直接令进程 abort，
        // 因此只把结构合法的 WAV 交给它；非法数据一律回退本地合成，避免「几秒后闪退」。
        guard Self.wavHeaderOK(data) else {
            AppLogger.log("playAudioData BAD WAV fallback to synth")
            if let notice { onCloudFallback?() }
            speakLocal(fallbackText)
            return
        }
        do {
            // 覆盖旧播放器前先停掉并摘除 delegate：
            // 旧实例的 didFinish 回调若延迟到达，会走 audioPlayerDidFinishPlaying→advance，
            // 与新段重复推进/串音；delegate 未摘除时旧对象还可能被回调访问。
            audioPlayer?.stop()
            audioPlayer?.delegate = nil
            let p = try AVAudioPlayer(data: data)
            p.delegate = self
            audioPlayer = p
            p.play()
        } catch {
            if let notice { onCloudFallback?() }
            speakLocal(fallbackText)
        }
    }

    /// 快速校验 WAV 头部是否结构合法（RIFF/WAVE + 能找到 data 块且声明长度不超出文件）。
    /// 仅做防御性预检，不解析音频内容；任何异常一律判为不合法。
    private static func wavHeaderOK(_ data: Data) -> Bool {
        guard data.count > 44 else { return false }
        guard data[0] == 0x52, data[1] == 0x49, data[2] == 0x46, data[3] == 0x46,   // RIFF
              data[8] == 0x57, data[9] == 0x41, data[10] == 0x56, data[11] == 0x45  // WAVE
        else { return false }
        var offset = 12
        var dataOffset = -1, dataSize = 0
        while offset + 8 <= data.count {
            let ck = String(data: data[offset..<offset + 4], encoding: .ascii) ?? ""
            let sz = Int(data[offset + 4]) | (Int(data[offset + 5]) << 8)
                      | (Int(data[offset + 6]) << 16) | (Int(data[offset + 7]) << 24)
            if ck == "data" { dataOffset = offset + 8; dataSize = sz; break }
            offset += 8 + sz + (sz & 1)
        }
        guard dataOffset > 0, dataSize > 0, dataOffset + dataSize <= data.count else { return false }
        return true
    }

    /// 本地合成（AVSpeechSynthesizer）。显示语速 × rateScale 换算为内部标度。
    /// 块尾带 "\n"（TextChunker 段落标记）→ 修剪并在读完后插入明显停顿，实现「按段停顿」。
    private func speakLocal(_ text: String) {
        synth.speak(buildUtterance(for: currentIndex, text: text))
    }


    private func advance() {
        AppLogger.log("advance idx=\(currentIndex)→\(currentIndex + 1) isPlaying=\(isPlaying)")
        // 停止后仍可能收到上一次朗读的完成回调，此时不得推进下一段（否则表现为「停了又继续读」）
        guard isPlaying else { return }
        currentIndex += 1
        speakCurrent()
    }

    /// 离线/云端音频路径的段间停顿：按刚读完的段落文本判定（章节开头 → 章节停顿；其余 → 短间隔）。
    private func pauseAfterCurrentSegment() -> TimeInterval {
        guard let raw = currentText() else { return 0.06 }
        // 与系统声路径一致：只认段首「第X章/回/卷」，避免段中提及章回名时误判成长停顿
        if raw.range(of: #"^\s*第[一二三四五六七八九十百千0-9]+[章回卷]"#, options: .regularExpression) != nil {
            return max(paragraphPause, chapterPause)
        }
        return 0.06
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
        Task { @MainActor in
            // 离线/云端音频没有 postUtteranceDelay，按刚读完的段落在推进前补停顿
            let d = self.pauseAfterCurrentSegment()
            if d > 0.05 {
                try? await Task.sleep(nanoseconds: UInt64(d * 1_000_000_000))
            }
            self.advance()
        }
    }
}
