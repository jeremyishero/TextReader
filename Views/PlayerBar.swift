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
        player.rate = settings.defaultRate
        player.autoVoiceSwitch = settings.autoVoiceSwitch

        let defaultVoice = resolveVoice(settings.defaultVoiceIdentifier)
            ?? TTSPlayer.pickVoice(preferGender: .neutral)
        player.setDefaultVoice(defaultVoice)
        player.setLanguageVoices(languageVoices(defaultVoice: defaultVoice))

        let start = startIndex ?? 0
        let cloud = cloudEnabled

        if useAnalyzed, let a = analysis, !a.segments.isEmpty {
            // 按性别池 + 轮转分配：男女分声、同性别的不同角色声音不同、同角色全程固定
            player.setRoleVoices(TTSPlayer.assignVoices(roles: a.roles))
            player.playSegments(a.segments, startIndex: start, cloud: cloud)
        } else {
            guard !text.isEmpty else { return }
            let chunks = TextChunker().chunk(text)
            player.playPlain(chunks, startIndex: start, cloud: cloud)
        }
        startIndex = nil   // 起点只生效一次
    }
}
