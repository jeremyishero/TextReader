import Foundation
import AVFoundation
import Combine

/// 全局设置：默认语速、三语声音（简/繁/英）、自动切声开关、云端 LLM 解析、云端 TTS。
/// 所有字段持久化到 UserDefaults。
@MainActor
final class AppSettings: ObservableObject {

    // MARK: 基础
    /// 默认语速（显示标度）：1.0 = 正常人语速，范围 0.5–3.0
    @Published var defaultRate: Float = 1.0 { didSet { save("defaultRate", defaultRate) } }
    @Published var defaultVoiceIdentifier: String? { didSet { save("defaultVoiceIdentifier", defaultVoiceIdentifier) } }
    /// 段落间停顿（秒）：默认 0（不停顿）；用户可在设置里调（0–5）
    @Published var paragraphPause: Double = 0 { didSet { save("paragraphPause", paragraphPause) } }
    /// 章节间停顿（秒）：读到「第X章/回/卷」开头时使用的停顿；默认 0（0–10）
    @Published var chapterPause: Double = 0 { didSet { save("chapterPause", chapterPause) } }

    // MARK: 按语言选声（v1 手动在设置里选声，朗读时按文本自动切换）
    @Published var voiceZhHans: String? { didSet { save("voiceZhHans", voiceZhHans) } }
    @Published var voiceZhHant: String? { didSet { save("voiceZhHant", voiceZhHant) } }
    @Published var voiceEn: String? { didSet { save("voiceEn", voiceEn) } }
    /// 中英混读/简繁混排时按段自动切换对应声音
    @Published var autoVoiceSwitch: Bool = true { didSet { save("autoVoiceSwitch", autoVoiceSwitch) } }

    /// 人名过滤名单：名单中的词（逗号/顿号/空格/换行分隔）永远不会被识别为角色名
    @Published var nameBlocklist: String = "" { didSet { save("nameBlocklist", nameBlocklist) } }

    // MARK: 云端 LLM 解析
    @Published var cloudLLMEnabled: Bool = false { didSet { save("cloudLLMEnabled", cloudLLMEnabled) } }
    /// OpenAI 兼容的 chat/completions 接口地址（可换成任意兼容服务商）
    @Published var cloudLLMEndpoint: String = "https://api.openai.com/v1/chat/completions" { didSet { save("cloudLLMEndpoint", cloudLLMEndpoint) } }
    @Published var cloudLLMApiKey: String = "" { didSet { save("cloudLLMApiKey", cloudLLMApiKey) } }
    @Published var cloudLLMModel: String = "gpt-4o-mini" { didSet { save("cloudLLMModel", cloudLLMModel) } }

    // MARK: 云端 TTS 备选通道
    @Published var cloudTTSEnabled: Bool = false { didSet { save("cloudTTSEnabled", cloudTTSEnabled) } }
    @Published var cloudTTSEndpoint: String = "https://api.openai.com/v1/audio/speech" { didSet { save("cloudTTSEndpoint", cloudTTSEndpoint) } }
    @Published var cloudTTSApiKey: String = "" { didSet { save("cloudTTSApiKey", cloudTTSApiKey) } }
    @Published var cloudTTSModel: String = "tts-1" { didSet { save("cloudTTSModel", cloudTTSModel) } }
    @Published var cloudTTSVoice: String = "alloy" { didSet { save("cloudTTSVoice", cloudTTSVoice) } }

    // MARK: 离线语音包（本地合成 · sherpa-onnx）
    @Published var offlineTTSEnabled: Bool = false { didSet { save("offlineTTSEnabled", offlineTTSEnabled) } }
    /// 当前使用的离线语音包 id（对应 OfflineTTSManager.packs）
    @Published var offlineTTSPackId: String = "" { didSet { save("offlineTTSPackId", offlineTTSPackId) } }
    /// 多音色包男声说话人编号列表（逗号分隔，男角色依次轮转使用不同男声）
    @Published var offlineTTSMaleSIDs: String = "0" { didSet { save("offlineTTSMaleSIDs", offlineTTSMaleSIDs) } }
    /// 多音色包女声说话人编号列表（逗号分隔，女角色依次轮转使用不同女声）
    @Published var offlineTTSFemaleSIDs: String = "1" { didSet { save("offlineTTSFemaleSIDs", offlineTTSFemaleSIDs) } }
    /// 每个语音包的性别标注：packId → "female"/"male"/"multi"（朗读按性别池轮转分配）
    @Published var offlinePackGenders: [String: String] = [
        "theresa": "female", "keqing": "female", "melo": "female",
        "eula": "female", "bronya": "female", "echo": "female",
        "zenyatta": "male", "fanchen-c": "male", "fanchen-unity": "",
        "aishell3": "multi",
        "abyssinvoker": "male", "zhihuilaozhe": "male",
        "doom": "", "zh-ll": "", "chaowen": "",
    ] { didSet { persistPackGenders() } }

    /// 旁白（叙述 / 默认）可改用已下载的离线语音包朗读（解决「旁白只能选系统几个声音」）。
    /// 为空字符串 "" 表示仍用系统默认声；否则为某个已安装离线包 id。
    @Published var narrationOfflinePackId: String = "" { didSet { save("narrationOfflinePackId", narrationOfflinePackId) } }
    /// 多音色包（如 AISHELL3）作旁白时的说话人编号；单音色包忽略。
    @Published var narrationOfflineSID: Int = 0 { didSet { save("narrationOfflineSID", narrationOfflineSID) } }

    /// 未播放时自动预合成后续内容（存磁盘缓存，播放时零等待）。仅在前台进行；进后台暂停以免被系统杀。
    @Published var autoPreSynthEnabled: Bool = false { didSet { save("autoPreSynthEnabled", autoPreSynthEnabled) } }
    /// 自动预合成段数（当前进度之后）。默认 30 段。
    @Published var autoPreSynthCount: Int = 30 { didSet { save("autoPreSynthCount", autoPreSynthCount) } }

    // MARK: 主角 / 配角声音槽（全局；按角色重要度自动分配，优先级低于角色面板手选）
    // 每个槽 = packId + sid。packId 为空表示该槽未设置，回退到现有分配逻辑。
    @Published var protagonist1PackId: String = "" { didSet { save("protagonist1PackId", protagonist1PackId) } }
    @Published var protagonist1SID: Int = 0 { didSet { save("protagonist1SID", protagonist1SID) } }
    @Published var protagonist2PackId: String = "" { didSet { save("protagonist2PackId", protagonist2PackId) } }
    @Published var protagonist2SID: Int = 0 { didSet { save("protagonist2SID", protagonist2SID) } }
    @Published var supporting1PackId: String = "" { didSet { save("supporting1PackId", supporting1PackId) } }
    @Published var supporting1SID: Int = 0 { didSet { save("supporting1SID", supporting1SID) } }
    @Published var supporting2PackId: String = "" { didSet { save("supporting2PackId", supporting2PackId) } }
    @Published var supporting2SID: Int = 0 { didSet { save("supporting2SID", supporting2SID) } }

    init() { load() }

    // MARK: 持久化

    private func persistPackGenders() {
        if let data = try? JSONEncoder().encode(offlinePackGenders) {
            UserDefaults.standard.set(data, forKey: "offlinePackGenders")
        }
    }

    private func load() {
        let d = UserDefaults.standard
        // 语速标度迁移：旧版 0.1–1.0（0.5=正常）→ 新版 0.5–3.0（1.0=正常），只执行一次
        if !d.bool(forKey: "rateScaleV2Migrated") {
            if d.object(forKey: "defaultRate") != nil {
                let old = d.float(forKey: "defaultRate")
                defaultRate = min(max(old * 2, 0.5), 3.0)
            }
            d.set(true, forKey: "rateScaleV2Migrated")
        }
        if d.object(forKey: "defaultRate") != nil { defaultRate = d.float(forKey: "defaultRate") }
        defaultVoiceIdentifier = d.string(forKey: "defaultVoiceIdentifier")
        // 停顿默认 0 迁移：老版本默认是 0.45/1.2，且滑块上限 5 秒，老用户可能缓存了很长停顿
        // （表现为每段之间停 5 秒以上）。首次升级忽略旧缓存、锁定为 0；之后尊重用户主动设置。
        if !d.bool(forKey: "pauseV2Migrated") {
            paragraphPause = 0
            chapterPause = 0
            d.set(true, forKey: "pauseV2Migrated")
        } else {
            if let p = d.object(forKey: "paragraphPause") as? Double { paragraphPause = min(max(p, 0), 5) }
            if let c = d.object(forKey: "chapterPause") as? Double { chapterPause = min(max(c, 0), 10) }
        }
        voiceZhHans = d.string(forKey: "voiceZhHans")
        voiceZhHant = d.string(forKey: "voiceZhHant")
        voiceEn = d.string(forKey: "voiceEn")
        if d.object(forKey: "autoVoiceSwitch") != nil { autoVoiceSwitch = d.bool(forKey: "autoVoiceSwitch") }
        if let b = d.string(forKey: "nameBlocklist") { nameBlocklist = b }
        if d.object(forKey: "cloudLLMEnabled") != nil { cloudLLMEnabled = d.bool(forKey: "cloudLLMEnabled") }
        if let e = d.string(forKey: "cloudLLMEndpoint"), !e.isEmpty { cloudLLMEndpoint = e }
        cloudLLMApiKey = d.string(forKey: "cloudLLMApiKey") ?? ""
        if let m = d.string(forKey: "cloudLLMModel"), !m.isEmpty { cloudLLMModel = m }
        if d.object(forKey: "cloudTTSEnabled") != nil { cloudTTSEnabled = d.bool(forKey: "cloudTTSEnabled") }
        if let e = d.string(forKey: "cloudTTSEndpoint"), !e.isEmpty { cloudTTSEndpoint = e }
        cloudTTSApiKey = d.string(forKey: "cloudTTSApiKey") ?? ""
        if let m = d.string(forKey: "cloudTTSModel"), !m.isEmpty { cloudTTSModel = m }
        if let v = d.string(forKey: "cloudTTSVoice"), !v.isEmpty { cloudTTSVoice = v }
        if d.object(forKey: "offlineTTSEnabled") != nil { offlineTTSEnabled = d.bool(forKey: "offlineTTSEnabled") }
        if let p = d.string(forKey: "offlineTTSPackId") { offlineTTSPackId = p }
        if let m = d.string(forKey: "offlineTTSMaleSIDs") { offlineTTSMaleSIDs = m }
        if let f = d.string(forKey: "offlineTTSFemaleSIDs") { offlineTTSFemaleSIDs = f }
        if let data = d.data(forKey: "offlinePackGenders"),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            offlinePackGenders = dict
        }
        if let p = d.string(forKey: "narrationOfflinePackId") { narrationOfflinePackId = p }
        if d.object(forKey: "narrationOfflineSID") != nil { narrationOfflineSID = d.integer(forKey: "narrationOfflineSID") }
        if d.object(forKey: "autoPreSynthEnabled") != nil { autoPreSynthEnabled = d.bool(forKey: "autoPreSynthEnabled") }
        if d.object(forKey: "autoPreSynthCount") != nil { autoPreSynthCount = d.integer(forKey: "autoPreSynthCount") }
        // 主角/配角声音槽
        if let p = d.string(forKey: "protagonist1PackId") { protagonist1PackId = p }
        if d.object(forKey: "protagonist1SID") != nil { protagonist1SID = d.integer(forKey: "protagonist1SID") }
        if let p = d.string(forKey: "protagonist2PackId") { protagonist2PackId = p }
        if d.object(forKey: "protagonist2SID") != nil { protagonist2SID = d.integer(forKey: "protagonist2SID") }
        if let p = d.string(forKey: "supporting1PackId") { supporting1PackId = p }
        if d.object(forKey: "supporting1SID") != nil { supporting1SID = d.integer(forKey: "supporting1SID") }
        if let p = d.string(forKey: "supporting2PackId") { supporting2PackId = p }
        if d.object(forKey: "supporting2SID") != nil { supporting2SID = d.integer(forKey: "supporting2SID") }
    }

    /// nil 值不能直接 set：首次启动 load() 会把 String? 属性置为 nil，didSet 触发本方法时
    /// Optional(nil) 若传入 setObject:forKey: 会被 CoreFoundation 校验拒绝
    /// （_CFPrefsValidateValueForKey → NSException → abort，见 TextReader-2026-11-05-091947.ips）。
    /// 因此 nil 统一走 removeObject，非 nil 才 set。
    private func save(_ key: String, _ value: Any?) {
        guard let value else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        UserDefaults.standard.set(value, forKey: key)
    }
}
