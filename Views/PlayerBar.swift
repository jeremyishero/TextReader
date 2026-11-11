import SwiftUI
import AVFoundation
import CoreLogic

/// 顶部播放控制条：回退 5 秒 / 播放·停止 / 前进 5 秒 / 语速（±0.5，点数值回 1.0×）/ 角色分声 / 目录。
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
        VStack(spacing: 6) {
            HStack(spacing: 14) {
                Button(action: { player.seek(by: -5) }) {
                    Image(systemName: "gobackward.5")
                }
                .help("回退 5 秒")
                .buttonStyle(.bordered)

                Button(action: toggleMainPlay) {
                    Label(player.isPlaying ? "停止" : "播放",
                          systemImage: player.isPlaying ? "stop.fill" : "play.fill")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)

                Button(action: { player.seek(by: 5) }) {
                    Image(systemName: "goforward.5")
                }
                .help("前进 5 秒")
                .buttonStyle(.bordered)

                speedControl

                Spacer()

                if analysis != nil {
                    Toggle("分声", isOn: $useAnalyzed)
                        .toggleStyle(.button)
                        .controlSize(.small)
                }
                Button(action: { onOpenTOC?() }) {
                    Image(systemName: "list.bullet")
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .onChange(of: restartToken) { _ in
            // 目录 ▶︎：正在播放则先停，再立即从新起点重新开始
            guard restartToken > 0 else { return }
            if player.isPlaying { player.stop() }
            startPlayback()
        }
    }

    // MARK: 速度控制（精度 0.5，点击数值一键回到 1.0×）

    private var speedControl: some View {
        HStack(spacing: 4) {
            Button { adjustRate(-0.5) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help("语速 -0.5")
            Button { player.rate = 1.0 } label: {
                Text(String(format: "%.1f×", player.rate))
                    .frame(minWidth: 44, alignment: .center)
            }
            .buttonStyle(.borderless)
            .font(.callout.monospacedDigit())
            .help("点击回到 1.0×")
            Button { adjustRate(0.5) } label: { Image(systemName: "plus.circle") }
                .buttonStyle(.borderless)
                .help("语速 +0.5")
        }
    }

    private func adjustRate(_ delta: Float) {
        player.rate = min(max(player.rate + delta, 0.5), 3.0)
    }

    // MARK: 主播放按钮：点击播放；播放中点击停止

    private func toggleMainPlay() {
        if player.isPlaying {
            player.stop()
        } else {
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

    /// 组装声音并从起点开始播放（顶部播放条的「播放」与「目录 ▶︎ 从本章朗读」共用）。
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
