import SwiftUI
import AVFoundation
import CoreLogic

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var offlineMgr = OfflineTTSManager.shared

    private var zhHansVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("zh-CN") }
    }
    private var zhHantVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.hasPrefix("zh-TW") || $0.language.hasPrefix("zh-HK") || $0.language.hasPrefix("zh-Hant")
        }
    }
    private var enVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("默认语速") {
                    Slider(value: $settings.defaultRate, in: 0.5...3.0, step: 0.05)
                    Text(String(format: "当前：%.2f×（1.0 = 正常人语速）", settings.defaultRate))
                }

                Section {
                    voicePicker("声音", voices: zhHansVoices, selection: $settings.voiceZhHans)
                } header: {
                    Text("简体中文声音（旁白 / 默认）")
                }

                Section {
                    voicePicker("声音", voices: zhHantVoices, selection: $settings.voiceZhHant)
                    Text("繁体内容（zh-TW / zh-HK）朗读时使用；未选择则用系统繁体默认声。")
                        .font(.caption).foregroundColor(.secondary)
                } header: {
                    Text("繁体中文声音")
                }

                Section {
                    voicePicker("声音", voices: enVoices, selection: $settings.voiceEn)
                    Toggle("自动切声（中英/简繁混排）", isOn: $settings.autoVoiceSwitch)
                    Text("开启后，每段朗读前自动判定文字语言并切换到对应声音（简体/繁体/英文）。")
                        .font(.caption).foregroundColor(.secondary)
                } header: {
                    Text("英文声音与混读切声")
                }

                Section("人名过滤名单（解析优化）") {
                    TextEditor(text: $settings.nameBlocklist)
                        .frame(minHeight: 80)
                        .autocorrectionDisabled()
                    Text("填入明确不是人名的词，用逗号、顿号、空格或换行分隔（如：很快，胡扯，安静）。解析时这些词将永远不被识别为角色。修改后需重新「整体解析」生效。")
                        .font(.caption).foregroundColor(.secondary)
                }

                Section("离线语音包（下载后免网络 · 推荐国内用户）") {
                    Toggle("启用离线语音包朗读", isOn: $settings.offlineTTSEnabled)
                    Text("下载到手机本地，完全离线合成，优先级高于云端 TTS。模型来自 sherpa-onnx 社区开放模型（国内经 hf-mirror 镜像下载）。")
                        .font(.caption).foregroundColor(.secondary)
                    Stepper("男声编号：\(settings.offlineTTSMaleSID)", value: $settings.offlineTTSMaleSID, in: 0...183)
                    Stepper("女声编号：\(settings.offlineTTSFemaleSID)", value: $settings.offlineTTSFemaleSID, in: 0...183)
                    Text("朗读时自动按角色性别分配音色：男角色用男声编号、女角色用女声编号（仅多音色包 AISHELL3 有效，单音色包忽略）。用各行试听按钮找到满意的编号后填到这里。")
                        .font(.caption2).foregroundColor(.secondary)
                    ForEach(OfflineTTSManager.packs) { pack in
                        packRow(pack)
                    }
                }

                Section("云端 TTS 备选通道（可选）") {
                    Toggle("启用云端 TTS", isOn: $settings.cloudTTSEnabled)
                    TextField("接口端点（OpenAI 兼容 /audio/speech）",
                              text: $settings.cloudTTSEndpoint)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("API Key", text: $settings.cloudTTSApiKey)
                    TextField("模型（如 tts-1）", text: $settings.cloudTTSModel)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("音色（如 alloy / echo / nova）", text: $settings.cloudTTSVoice)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Text("开启后优先用云端合成（更自然），失败或离线时自动回退本地语音。文本内容将发送到你配置的接口。")
                        .font(.caption).foregroundColor(.secondary)
                }

                Section("云端 LLM 解析（可选 · 更高准确度）") {
                    Toggle("启用云端解析", isOn: $settings.cloudLLMEnabled)
                    TextField("接口端点（OpenAI 兼容 /chat/completions）",
                              text: $settings.cloudLLMEndpoint)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("API Key", text: $settings.cloudLLMApiKey)
                    TextField("模型（如 gpt-4o-mini / deepseek-chat）", text: $settings.cloudLLMModel)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Text("开启后，「整体解析」会先尝试调用云端大模型；文本内容将发送至你配置的接口。失败时自动回退本地引擎并以轻提示告知原因。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func voicePicker(_ label: String, voices: [AVSpeechSynthesisVoice], selection: Binding<String?>, previewText: String = "你好，我是中国人") -> some View {
        HStack(spacing: 8) {
            Picker(label, selection: selection) {
                Text("系统默认").tag(String?.none)
                ForEach(voices, id: \.identifier) { v in
                    Text("\(v.name)（\(v.language)）").tag(String?.some(v.identifier))
                }
            }
            // 预听：选定前先听听这个声音的效果
            Button {
                let voice = selection.wrappedValue.flatMap { AVSpeechSynthesisVoice(identifier: $0) }
                VoicePreviewer.shared.preview(voice)
                _ = previewText
            } label: {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("预听\(label)")
        }
    }

    // MARK: 离线语音包行

    @ViewBuilder
    private func packRow(_ pack: VoicePackInfo) -> some View {
        let installed = offlineMgr.isInstalled(pack.id)
        let isCurrent = settings.offlineTTSEnabled && settings.offlineTTSPackId == pack.id
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(pack.displayName)
                    if isCurrent {
                        Text("使用中")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15))
                            .foregroundColor(.accentColor)
                            .cornerRadius(4)
                    }
                }
                Text("\(pack.gender) · 约 \(pack.sizeMB)MB")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                if offlineMgr.downloading.contains(pack.id) {
                    ProgressView(value: offlineMgr.progress[pack.id] ?? 0)
                        .progressViewStyle(.linear)
                }
            }
            Spacer()
            if let err = offlineMgr.errors[pack.id] {
                Text(err)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .frame(maxWidth: 130, alignment: .trailing)
            }
            if offlineMgr.downloading.contains(pack.id) {
                Text("\(Int((offlineMgr.progress[pack.id] ?? 0) * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            } else if installed {
                // 预听：女声编号 / 男声编号（多音色包有效；单音色包两键同声）
                Button {
                    previewOfflinePack(pack, gender: .female)
                } label: {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("女声试听")
                Button {
                    previewOfflinePack(pack, gender: .male)
                } label: {
                    Image(systemName: "person.wave.2.fill")
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("男声试听")
                // 启用 / 停用
                Button(isCurrent ? "停用" : "使用") {
                    settings.offlineTTSPackId = isCurrent ? "" : pack.id
                    settings.offlineTTSEnabled = !isCurrent
                }
                .font(.caption)
                .buttonStyle(.bordered)
                // 删除
                Button {
                    offlineMgr.deletePack(pack.id)
                    if settings.offlineTTSPackId == pack.id {
                        settings.offlineTTSPackId = ""
                        settings.offlineTTSEnabled = false
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundColor(.red)
                }
                .buttonStyle(.borderless)
            } else {
                Button("下载") {
                    settings.offlineTTSPackId = pack.id   // 预选：装完即用
                    settings.offlineTTSEnabled = true
                    offlineMgr.download(pack)
                }
                .font(.caption)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 2)
    }

    /// 用离线语音包按性别编号合成一句试听并播放
    private func previewOfflinePack(_ pack: VoicePackInfo, gender: Gender) {
        Task {
            if let wav = await offlineMgr.synthesize(
                text: "你好，我是中国人",
                packId: pack.id,
                gender: gender,
                maleSID: Int32(settings.offlineTTSMaleSID),
                femaleSID: Int32(settings.offlineTTSFemaleSID),
                speed: 1.0
            ) {
                VoicePreviewer.shared.playAudio(wav)
            }
        }
    }
}
