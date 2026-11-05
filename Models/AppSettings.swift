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

    // MARK: 按语言选声（v1 手动在设置里选声，朗读时按文本自动切换）
    @Published var voiceZhHans: String? { didSet { save("voiceZhHans", voiceZhHans) } }
    @Published var voiceZhHant: String? { didSet { save("voiceZhHant", voiceZhHant) } }
    @Published var voiceEn: String? { didSet { save("voiceEn", voiceEn) } }
    /// 中英混读/简繁混排时按段自动切换对应声音
    @Published var autoVoiceSwitch: Bool = true { didSet { save("autoVoiceSwitch", autoVoiceSwitch) } }

    // MARK: 云端 LLM 解析
    @Published var cloudLLMEnabled: Bool = false { didSet { save("cloudLLMEnabled", cloudLLMEnabled) } }
    @Published var cloudLLMApiKey: String = "" { didSet { save("cloudLLMApiKey", cloudLLMApiKey) } }

    // MARK: 云端 TTS 备选通道
    @Published var cloudTTSEnabled: Bool = false { didSet { save("cloudTTSEnabled", cloudTTSEnabled) } }
    @Published var cloudTTSEndpoint: String = "https://api.openai.com/v1/audio/speech" { didSet { save("cloudTTSEndpoint", cloudTTSEndpoint) } }
    @Published var cloudTTSApiKey: String = "" { didSet { save("cloudTTSApiKey", cloudTTSApiKey) } }
    @Published var cloudTTSModel: String = "tts-1" { didSet { save("cloudTTSModel", cloudTTSModel) } }
    @Published var cloudTTSVoice: String = "alloy" { didSet { save("cloudTTSVoice", cloudTTSVoice) } }

    init() { load() }

    // MARK: 持久化

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
        voiceZhHans = d.string(forKey: "voiceZhHans")
        voiceZhHant = d.string(forKey: "voiceZhHant")
        voiceEn = d.string(forKey: "voiceEn")
        if d.object(forKey: "autoVoiceSwitch") != nil { autoVoiceSwitch = d.bool(forKey: "autoVoiceSwitch") }
        if d.object(forKey: "cloudLLMEnabled") != nil { cloudLLMEnabled = d.bool(forKey: "cloudLLMEnabled") }
        cloudLLMApiKey = d.string(forKey: "cloudLLMApiKey") ?? ""
        if d.object(forKey: "cloudTTSEnabled") != nil { cloudTTSEnabled = d.bool(forKey: "cloudTTSEnabled") }
        if let e = d.string(forKey: "cloudTTSEndpoint"), !e.isEmpty { cloudTTSEndpoint = e }
        cloudTTSApiKey = d.string(forKey: "cloudTTSApiKey") ?? ""
        if let m = d.string(forKey: "cloudTTSModel"), !m.isEmpty { cloudTTSModel = m }
        if let v = d.string(forKey: "cloudTTSVoice"), !v.isEmpty { cloudTTSVoice = v }
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
