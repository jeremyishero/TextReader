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
    /// voiceOverrides 字典里的保留 key：本书旁白声音（优先于全局系统设置）。
    /// 编码与角色声音一致：preset:<id> / 离线包编码 / 系统声 identifier。
    /// 放在无 @MainActor 隔离的 enum 里，供离线合成闭包等非隔离上下文访问。
    static let narrationVoiceKey = "__narration__"

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
    /// 含 primary+special+standby 全部启用音色——让所有角色都能选到声音，不再局限于正式池。
    static func manualOptions() -> [(id: String, name: String)] {
        all().filter { $0.enabled }
            .map { ("preset:" + $0.id, "预设｜" + $0.label + ($0.tier == "standby" ? "（备用）" : "")) }
    }

    /// 不重复的全局音色分配：按传入角色顺序，为每类音色依次分配一个未被占用的预设。
    /// 同一角色稳定（外部按稳定排序的角色列表调用）；音色用完则为 nil（调用方回退系统默认声）。
    /// - Parameters:
    ///   - orderedRoles: 已按频次降序排好的 (id, gender)；主角在前。
    ///   - overrides: 用户手动指定的角色音色（preset:<id>），这些角色占用其指定音色且不再参与自动分配。
    /// - Returns: 角色 id → (packId, sid, speed, label)；未分配的角色不在字典中（回退系统默认）。
    static func assignDistinct(orderedRoles: [(id: String, gender: Gender)],
                               overrides: [String: String] = [:])
        -> [String: (packId: String, sid: Int32, speed: Float, label: String)] {
        let enabled = all().filter { $0.enabled }
        func pool(for g: Gender) -> [VoicePreset] {
            switch g {
            case .eunuch: return enabled.filter { $0.gender == .eunuch }
            case .male:   return enabled.filter { $0.gender == .male || $0.gender == .eunuch }
            case .female: return enabled.filter { $0.gender == .female }
            case .neutral: return []
            }
        }
        var result: [String: (packId: String, sid: Int32, speed: Float, label: String)] = [:]
        var used = Set<String>()   // 已占用的 preset.id，保证不同角色不同音色
        // 先落实手动指定：按角色顺序，指定音色即占用
        for r in orderedRoles {
            if let code = overrides[r.id], let p = byEncoded(code) {
                result[r.id] = (p.packId, p.sid, p.speed, p.label)
                used.insert(p.id)
            }
        }
        // 再自动分配未指定的角色：按频次顺序依次取该性别池里未被占用的第一个
        // 池用尽 → 该角色不分配（外部回退系统默认声）
        for r in orderedRoles where result[r.id] == nil {
            guard let p = pool(for: r.gender).first(where: { !used.contains($0.id) }) else { continue }
            result[r.id] = (p.packId, p.sid, p.speed, p.label)
            used.insert(p.id)
        }
        return result
    }

    /// 由 voiceOverrides 的编码还原预设。
    static func byEncoded(_ encoded: String) -> VoicePreset? {
        guard encoded.hasPrefix("preset:") else { return nil }
        let id = String(encoded.dropFirst("preset:".count))
        return all().first { $0.id == id }
    }
}
