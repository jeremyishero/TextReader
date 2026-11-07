import SwiftUI
import AVFoundation
import CoreLogic

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var offlineMgr = OfflineTTSManager.shared
    @State private var showPackImporter = false
    @State private var packImportMsg: String? = nil

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
                    TextField("男声编号列表（逗号分隔，如 0,3,7）", text: $settings.offlineTTSMaleSIDs)
                        .font(.caption)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("女声编号列表（逗号分隔，如 1,2,5）", text: $settings.offlineTTSFemaleSIDs)
                        .font(.caption)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Text("多音色包（AISHELL3，174 人）朗读时：男角色依次轮转男声编号列表、女角色依次轮转女声编号列表——不同角色自动配不同声音。单音色包忽略编号。先下载并试听，把满意的男女声编号填进来（逗号分隔可填多个）。")
                        .font(.caption2).foregroundColor(.secondary)
                    Text("角色分配规则：优先在已下载的「女声」包之间轮转（女角色）/「男声」包之间轮转（男角色）；没有对应性别包时用多音色包按编号列表轮转。每个角色分配后固定不变，改标注或编号后下次朗读重新分配。")
                        .font(.caption2).foregroundColor(.secondary)
                    ForEach(OfflineTTSManager.packs) { pack in
                        packRow(pack)
                    }
                    Button {
                        showPackImporter = true
                    } label: {
                        Label("从文件导入语音包(.zip)", systemImage: "square.and.arrow.down")
                            .font(.caption)
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
            .fileImporter(
                isPresented: $showPackImporter,
                allowedContentTypes: [UTType(filenameExtension: "zip") ?? .zip, .data],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first { importPackFromURL(url) }
                case .failure(let error):
                    guard (error as? CocoaError)?.code != .userCancelled else { return }
                    packImportMsg = "打开文件选择器失败：" + error.localizedDescription
                }
            }
            .alert("语音包导入", isPresented: Binding(
                get: { packImportMsg != nil },
                set: { if !$0 { packImportMsg = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(packImportMsg ?? "")
            }
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
        // 读取 revision 建立刷新依赖：磁盘安装状态一变，该行立即重算
        let installed = offlineMgr.isInstalled(pack.id) && offlineMgr.revision >= 0
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
                // 性别标注：决定该包进入哪个性别池（女声池/男声池/多音色）
                if installed {
                    Picker("性别标注", selection: Binding(
                        get: { settings.offlinePackGenders[pack.id] ?? "" },
                        set: { newValue in
                            settings.offlinePackGenders[pack.id] = newValue
                            offlineMgr.resetAssignments()
                        }
                    )) {
                        Text("标注：女声").tag("female")
                        Text("标注：男声").tag("male")
                        Text("标注：多音色").tag("multi")
                        Text("标注：不参与").tag("")
                    }
                    .font(.caption2)
                    .pickerStyle(.menu)
                }
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
                // 启用 / 停用（多包轮转模式下不再需要单独启用，保留用于主旁白声指定）
                Button(isCurrent ? "停用" : "设为旁白") {
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

    /// 从本地 zip 导入语音包（电脑代下后隔空投送/文件 App 传输）
    private func importPackFromURL(_ url: URL) {
        if let err = offlineMgr.importPackZip(from: url) {
            packImportMsg = "导入失败：" + err
        } else {
            packImportMsg = "导入成功！点该语音包行的「使用」即可启用。"
        }
    }

    /// 用离线语音包按性别编号列表的第一个合成试听（多音色包换列表第一个值再试听可挑音色）
    private func previewOfflinePack(_ pack: VoicePackInfo, gender: Gender) {
        Task {
            let sidList = gender == .male
                ? settings.offlineTTSMaleSIDs.split(separator: ",").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
                : settings.offlineTTSFemaleSIDs.split(separator: ",").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
            if let wav = await offlineMgr.synthesizePreview(
                text: "你好，我是中国人",
                packId: pack.id,
                sid: sidList.first ?? (gender == .male ? 0 : 1),
                speed: 1.0
            ) {
                VoicePreviewer.shared.playAudio(wav)
            }
        }
    }
}
