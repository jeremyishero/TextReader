import SwiftUI
import AVFoundation
import CoreLogic

/// 底部播放控制条：播放/暂停/停止、语速、是否启用角色分声、断点续读。
struct PlayerBar: View {
    @EnvironmentObject var player: TTSPlayer
    @EnvironmentObject var settings: AppSettings

    let text: String
    let analysis: AnalysisResult?
    @Binding var useAnalyzed: Bool
    @Binding var startIndex: Int?   // 外部（ReadingView）传入的续读起点
    var voiceOverrides: [String: String] = [:]   // 每文档声音配置：角色称呼 → 声音 identifier
    var onOpenTOC: (() -> Void)? = nil           // 打开章节目录
    var restartToken: Int = 0                    // 外部（目录 ▶︎）递增时：立即从新起点重新开始播放

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                Button(action: togglePlay) {
                    Label(player.isPlaying ? "暂停" : "播放",
                          systemImage: player.isPlaying ? "pause.fill" : "play.fill")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)

                Button(action: { player.stop() }) {
                    Label("停止", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)

                Button {
                    onOpenTOC?()
                } label: {
                    Label("目录", systemImage: "list.bullet")
                }
                .buttonStyle(.bordered)
            }

            HStack {
                Text("语速")
                Slider(value: $player.rate, in: 0.5...3.0, step: 0.05)
                Text(String(format: "%.2f×", player.rate))
                    .frame(width: 52, alignment: .trailing)
                    .font(.caption.monospacedDigit())
            }

            if analysis != nil {
                Toggle("角色分声朗读（按人物/情绪）", isOn: $useAnalyzed)
            }
        }
        .padding()
        .background(.thinMaterial)
        .onChange(of: restartToken) { _ in
            // 目录 ▶︎：正在播放则先停，再立即从新起点重新开始
            guard restartToken > 0 else { return }
            if player.isPlaying { player.stop() }
            startPlayback()
        }
    }

    // MARK: 声音装配

    private func resolveVoice(_ identifier: String?) -> AVSpeechSynthesisVoice? {
        identifier.flatMap { AVSpeechSynthesisVoice(identifier: $0) }
    }

    /// 简体/繁体/英文三语声音映射（v1 由用户在设置页手动选声）
    private func languageVoices(defaultVoice: AVSpeechSynthesisVoice?) -> [ScriptLanguage: AVSpeechSynthesisVoice] {
        var map: [ScriptLanguage: AVSpeechSynthesisVoice] = [:]
        if let v = resolveVoice(settings.voiceZhHans) ?? defaultVoice ?? TTSPlayer.pickVoice(language: "zh-CN") {
            map[.zhHans] = v
        }
        if let v = resolveVoice(settings.voiceZhHant) ?? TTSPlayer.pickVoice(language: "zh-TW") {
            map[.zhHant] = v
        }
        if let v = resolveVoice(settings.voiceEn) ?? TTSPlayer.pickVoice(language: "en-US") {
            map[.english] = v
        }
        return map
    }

    private var cloudEnabled: Bool {
        settings.cloudTTSEnabled && !settings.cloudTTSApiKey.isEmpty
    }

    // MARK: 播放

    private func togglePlay() {
        if player.isPlaying {
            player.pause()
            return
        }
        startPlayback()
    }

    /// 组装声音并从起点开始播放（togglePlay 与「目录 ▶︎ 从本章朗读」共用）。
    private func startPlayback() {
        player.rate = settings.defaultRate
        player.autoVoiceSwitch = settings.autoVoiceSwitch

        let defaultVoice = resolveVoice(settings.defaultVoiceIdentifier)
            ?? TTSPlayer.pickVoice(preferGender: .neutral)
        player.setDefaultVoice(defaultVoice)
        player.setLanguageVoices(languageVoices(defaultVoice: defaultVoice))

        let start = startIndex ?? 0
        let cloud = cloudEnabled

        if useAnalyzed, let a = analysis, !a.segments.isEmpty {
            // 先按性别池自动分配（含性别音高补偿），再套用本文档的手动声音配置（按角色称呼匹配，仅对本文档生效）
            let assign = TTSPlayer.assignVoicesAndPitches(roles: a.roles)
            var map: [String: AVSpeechSynthesisVoice] = [:]
            var pitches: [String: Float] = [:]
            for role in a.roles {
                if let identifier = voiceOverrides[role.canonicalName],
                   let v = AVSpeechSynthesisVoice(identifier: identifier) {
                    map[role.id] = v
                    pitches[role.id] = 1.0   // 手动指定声音后不叠加性别音高补偿
                } else {
                    map[role.id] = assign.voices[role.id]
                    pitches[role.id] = assign.pitches[role.id] ?? 1.0
                }
            }
            var genders: [String: Gender] = [:]
            for role in a.roles { genders[role.id] = role.gender }
            player.setRoleGenders(genders)
            player.setRoleVoices(map)
            player.setRolePitches(pitches)
            player.playSegments(a.segments, startIndex: start, cloud: cloud)
        } else {
            guard !text.isEmpty else { return }
            let chunks = TextChunker().chunk(text)
            player.playPlain(chunks, startIndex: start, cloud: cloud)
        }
        startIndex = nil   // 起点只生效一次
    }
}
