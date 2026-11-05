import SwiftUI
import AVFoundation

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

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
    private func voicePicker(_ label: String, voices: [AVSpeechSynthesisVoice], selection: Binding<String?>) -> some View {
        Picker(label, selection: selection) {
            Text("系统默认").tag(String?.none)
            ForEach(voices, id: \.identifier) { v in
                Text("\(v.name)（\(v.language)）").tag(String?.some(v.identifier))
            }
        }
    }
}
