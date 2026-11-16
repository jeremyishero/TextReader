import Foundation
import CoreLogic

/// 48 角色音色预设（VoicePresets.json 随 App 分发，PC 端试听器共用同一份数据）。
/// 每条预设 = 某个语音包 + 说话人编号(sid) + 语速微调，标签（男/女/年龄/粗细）来自用户试听纠正。
struct VoicePreset: Identifiable {
    let id: String
    let label: String
    let gender: Gender
    let tier: String          // primary=正式 / special=专用(太监) / standby=备用
    let packId: String
    let sid: Int32
    let speed: Float
    let enabled: Bool
}

/// 预设联动：
/// - 自动分配：按角色性别（太监→专用池）从「正式+专用」池稳定分配——同一角色永远同一声音；
/// - 手动选声：以 "preset:<id>" 编码进 voiceOverrides（与系统声/离线包选项并列）。
enum VoicePresetProvider {

    private static var cache: [VoicePreset] = []
    private static var loaded = false
    private static let lock = NSLock()

    /// 读 bundle 内 VoicePresets.json（只解析一次）。
    static func all() -> [VoicePreset] {
        lock.lock(); defer { lock.unlock() }
        if loaded { return cache }
        loaded = true
        guard let url = Bundle.main.url(forResource: "VoicePresets", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let arr = obj["presets"] as? [[String: Any]] else { return [] }
        let gmap: [String: Gender] = ["male": .male, "female": .female,
                                      "neutral": .neutral, "eunuch": .eunuch]
        for it in arr {
            guard let id = it["id"] as? String,
                  let packId = it["packId"] as? String,
                  let g = gmap[it["gender"] as? String ?? ""],
                  let sidNum = it["sid"] as? NSNumber else { continue }
            let speed = (it["speed"] as? NSNumber)?.doubleValue ?? 1.0
            cache.append(VoicePreset(id: id,
                                     label: (it["label"] as? String) ?? id,
                                     gender: g,
                                     tier: (it["tier"] as? String) ?? "standby",
                                     packId: packId,
                                     sid: sidNum.int32Value,
                                     speed: Float(speed),
                                     enabled: (it["enabled"] as? Bool) ?? true))
        }
        return cache
    }

    /// 自动分配：同一 characterId 稳定哈希 → 永远命中同一预设（声音不漂移）；
    /// 不同角色哈希自然分散到池内不同音色。旁白（characterId 为空）固定取池中第一个。
    /// 中性角色不参与预设（仍走旧的男/女轮转兜底）。
    static func assign(gender: Gender, characterId: String) -> VoicePreset? {
        let pool = all().filter { $0.enabled && $0.tier == "primary" || $0.enabled && $0.tier == "special" }
        let candidates: [VoicePreset]
        switch gender {
        case .eunuch:  candidates = pool.filter { $0.gender == .eunuch }
        case .male:    candidates = pool.filter { $0.gender == .male }
        case .female:  candidates = pool.filter { $0.gender == .female }
        case .neutral: return nil
        }
        guard !candidates.isEmpty else { return nil }
        if characterId.isEmpty { return candidates[0] }
        // FNV-1a 稳定哈希
        var h: UInt64 = 1469598103934665603
        for b in characterId.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return candidates[Int(h % UInt64(candidates.count))]
    }

    /// 手动选声选项（AnalysisView）：「预设｜音色名」，编码为 preset:<id>。
    static func manualOptions() -> [(id: String, name: String)] {
        all().filter { $0.enabled && ($0.tier == "primary" || $0.tier == "special") }
            .map { ("preset:" + $0.id, "预设｜" + $0.label) }
    }

    /// 由 voiceOverrides 的编码还原预设。
    static func byEncoded(_ encoded: String) -> VoicePreset? {
        guard encoded.hasPrefix("preset:") else { return nil }
        let id = String(encoded.dropFirst("preset:".count))
        return all().first { $0.id == id }
    }
}
