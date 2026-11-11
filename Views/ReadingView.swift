import SwiftUI
import CoreLogic
import AVFoundation

struct ReadingView: View {
    @EnvironmentObject var store: DocumentStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var player: TTSPlayer
    @Environment(\.scenePhase) private var scenePhase
    let item: DocumentItem

    @State private var text: String = ""
    @State private var paragraphs: [String] = []
    @State private var analysis: AnalysisResult?
    @State private var analysisSource: String?          // "cloud" / "local"
    @State private var isAnalyzing = false
    @State private var showAnalysis = false
    @State private var pendingStart: Int? = nil   // 断点续读起始段
    @State private var lastSaveAt = Date.distantPast
    @State private var analysisErrorMessage: String?
    @State private var statusMessage: String?           // 圆灯点击后显示的状态
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?
    @State private var analysisTask: Task<Void, Never>?
    @State private var highlightIndex: Int?             // 正在朗读的段落
    @State private var segmentToParagraph: [String: Int] = [:]   // 朗读段 → 段落索引缓存（避免重复扫描与跳段）
    @State private var showModeDialog = false           // 整体解析：先选择本地/云端
    @State private var voiceOverrides: [String: String] = [:]    // 每文档声音配置：角色称呼 → 声音 identifier
    @State private var docBlacklist: [String] = []      // 每文档人名黑名单
    @State private var docWhitelist: [String] = []      // 每文档人名白名单
    @State private var docRules: [CustomRule] = []      // 每文档自定义朗读规则（≤20 条）
    @State private var showTOC = false                  // 章节目录
    @State private var chapterList: [(index: Int, title: String)] = []   // (段落索引, 章节标题)

    var body: some View {
        VStack(spacing: 0) {
            if let p = item.progress {
                BannerView(text: "上次读到第 \(p.segmentIndex + 1) 段") {
                    pendingStart = p.segmentIndex
                    player.requestStartPlayback(from: p.segmentIndex)
                }
            }
            if paragraphs.isEmpty {
                ScrollView {
                    Text("（未能提取到文本，可能是扫描版 PDF 或空文件）")
                        .padding()
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                // 分段懒加载渲染：整本小说也不会卡死；朗读时同步高亮并自动滚动到当前段
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(paragraphs.indices, id: \.self) { idx in
                                ParagraphRow(text: paragraphs[idx],
                                             isHighlighted: highlightIndex == idx,
                                             index: idx)
                            }
                        }
                        .padding()
                    }
                    .onReceive(player.$nowSpeakingText) { speaking in
                        guard let speaking, !speaking.isEmpty else { return }
                        let idx = paragraphIndex(for: speaking)
                        if let idx, idx != highlightIndex {
                            highlightIndex = idx
                            withAnimation {
                                proxy.scrollTo(idx, anchor: .center)
                            }
                        }
                    }
                    // 章节目录（在 ScrollViewReader 作用域内，才能用 proxy 跳转）
                    .sheet(isPresented: $showTOC) {
                        tocSheet(proxy: proxy)
                    }
                }
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { readerToolbar }
        .overlay { feedbackOverlay }
        .alert(
            "解析失败",
            isPresented: Binding(
                get: { analysisErrorMessage != nil },
                set: { if !$0 { analysisErrorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(analysisErrorMessage ?? "")
        }
        .alert(
            "解析状态",
            isPresented: Binding(
                get: { statusMessage != nil },
                set: { if !$0 { statusMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(statusMessage ?? "")
        }
        .sheet(isPresented: $showAnalysis) {
            if let binding = Binding($analysis) {
                AnalysisView(
                    analysis: binding,
                    blacklisted: docBlacklist,
                    whitelisted: docWhitelist,
                    voiceOverrides: voiceOverrides,
                    otherDocuments: store.documentsWithVoiceConfig(excluding: item.id),
                    rules: docRules,
                    onEdited: {
                        // 用户改名/删除角色后，把最新结果写回持久缓存（圆灯颜色不变）
                        if let a = analysis {
                            store.saveAnalysis(a, source: analysisSource ?? "local", for: item.id)
                        }
                    },
                    onListsChanged: { black, white in
                        docBlacklist = black
                        docWhitelist = white
                        store.saveNameLists(black: black, white: white, for: item.id)
                    },
                    onVoiceChanged: { assignments in
                        voiceOverrides = assignments
                        store.saveVoiceConfig(assignments, for: item.id)
                    },
                    onImportConfig: { sourceDoc in
                        // 从其他文档导入人物配置：按角色称呼匹配，只影响当前文档
                        let cfg = store.loadVoiceConfig(for: sourceDoc.id)
                        var merged = voiceOverrides
                        if let a = analysis {
                            for role in a.roles {
                                if let v = cfg[role.canonicalName] {
                                    merged[role.canonicalName] = v
                                }
                            }
                        }
                        voiceOverrides = merged
                        store.saveVoiceConfig(merged, for: item.id)
                        showToast("已导入「\(sourceDoc.name)」的人物声音配置（仅对本文档生效）")
                    },
                    onRulesChanged: { rules in
                        docRules = rules
                        store.saveRules(rules, for: item.id)
                        player.customRules = rules   // 朗读中即时生效
                    }
                )
            }
        }
        .confirmationDialog(
            "选择解析方式",
            isPresented: $showModeDialog,
            titleVisibility: .visible
        ) {
            Button("本地解析（离线 · 快）") { runAnalysis(mode: .local) }
            Button("云端解析（更准 · 需网络与 API Key）") { runAnalysis(mode: .cloud) }
                .disabled(!(settings.cloudLLMEnabled && !settings.cloudLLMApiKey.isEmpty))
            Button("取消", role: .cancel) {}
        } message: {
            Text("云端解析未配置或失败时，将自动回退本地解析并提示原因。")
        }
        .task { loadText() }
        .onAppear {
            configurePlayer()
            player.activeTitle = item.name
            player.openTOCHandler = { showTOC = true }
            player.startPlaybackHandler = { idx in self.startPlayback(from: idx) }
        }
        .onChange(of: scenePhase) { phase in
            // 从后台/锁屏回到前台时，立即把高亮同步到当前朗读位置
            if phase == .active { syncHighlightNow() }
        }
        .onDisappear {
            saveProgressNow()
            player.onIndexChange = nil
            player.onCloudFallback = nil
            player.startPlaybackHandler = nil
            player.openTOCHandler = nil
        }
    }

    // MARK: 工具栏与反馈浮层

    @ToolbarContentBuilder
    private var readerToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Button("整体解析") { showModeDialog = true }
                .disabled(isAnalyzing || text.isEmpty)
        }
        // 解析状态指示灯：灰=未解析，蓝=本地解析，绿=云端解析；点击显示状态文字
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                statusMessage = statusText
            } label: {
                Circle()
                    .fill(lampColor)
                    .frame(width: 9, height: 9)
            }
            .accessibilityLabel("解析状态指示灯")
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button("解析结果") { showAnalysis = true }
                .disabled(analysis == nil)
        }
    }

    @ViewBuilder
    private var feedbackOverlay: some View {
        // 规范：解析耗时可能超过 1 秒 → 全屏进度框（可取消）；静默回退/成功提示 → 轻提示；失败 → Alert
        if isAnalyzing {
            BusyHUD(title: "正在解析人物与情绪，请稍候…", onCancel: {
                analysisTask?.cancel()
                isAnalyzing = false
            })
        } else if let toast {
            ToastView(text: toast, isErrorStyle: true)
        }
    }

    // MARK: 数据加载

    private func loadText() {
        guard let t = store.text(for: item) else { return }
        text = t
        // 按自然段拆分：大文件懒加载渲染不卡顿，且可逐段高亮
        paragraphs = t.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // 恢复该文档此前保存的解析结果与小圆灯颜色（重进/重启不丢失）
        if let cached = store.loadAnalysis(for: item.id) {
            analysis = cached.result
            analysisSource = cached.source
            player.useAnalyzedPlayback = true
        }
        // 恢复每文档的声音配置与黑白名单
        voiceOverrides = store.loadVoiceConfig(for: item.id)
        let lists = store.loadNameLists(for: item.id)
        docBlacklist = lists.black
        docWhitelist = lists.white
        // 恢复自定义朗读规则并注入播放器
        docRules = store.loadRules(for: item.id)
        player.customRules = docRules
        // 章节目录：形如「第X章/回/卷/节 …」的短段落
        chapterList = Self.detectChapters(in: paragraphs)
        // 若朗读仍在进行（如从后台/锁屏返回），立即把高亮同步到当前位置
        syncHighlightNow()
    }

    /// 章节检测：短段落且以「第X章/回/卷/节」开头
    static func detectChapters(in paragraphs: [String]) -> [(index: Int, title: String)] {
        guard let re = try? NSRegularExpression(pattern: "^第[一二三四五六七八九十百千0-9]+[章回卷节]") else { return [] }
        var out: [(Int, String)] = []
        for (idx, p) in paragraphs.enumerated() {
            guard p.count <= 40 else { continue }
            let ns = p as NSString
            if re.firstMatch(in: p, range: NSRange(location: 0, length: ns.length)) != nil {
                out.append((idx, p))
            }
        }
        return out
    }

    // MARK: 章节目录

    /// 当前朗读位置所在章节（段落索引）
    private var currentChapterParagraph: Int? {
        guard let h = highlightIndex else { return nil }
        return chapterList.filter { $0.index <= h }.last?.index
    }

    /// 章节目录 sheet（在 ScrollViewReader 作用域内构建，tap 才能滚动定位）
    private func tocSheet(proxy: ScrollViewProxy) -> some View {
        NavigationStack {
            List {
                if chapterList.isEmpty {
                    Text("未检测到章节标记（形如「第X章 …」的独立段落）。")
                        .foregroundColor(.secondary)
                }
                ForEach(chapterList, id: \.index) { ch in
                    HStack(spacing: 10) {
                        Text(ch.title)
                            .lineLimit(1)
                            .foregroundColor(currentChapterParagraph == ch.index ? .accentColor : .primary)
                        if currentChapterParagraph == ch.index {
                            Text("当前")
                                .font(.caption2)
                                .foregroundColor(.accentColor)
                        }
                        Spacer()
                        // 从本章开始朗读：把章节段落映射为朗读分段起点，并立即开始播放
                        Button {
                            showTOC = false
                            if let seg = nearestSegmentIndex(forParagraph: ch.index) {
                                pendingStart = seg
                                player.requestStartPlayback(from: seg)   // 立即从本章起点开始朗读
                                showToast("正在从「\(ch.title)」开始朗读")
                            }
                        } label: {
                            Image(systemName: "play.circle")
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.borderless)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // 视图跳转：滚动到该章节段落
                        showTOC = false
                        withAnimation {
                            proxy.scrollTo(ch.index, anchor: .top)
                        }
                    }
                }
            }
            .navigationTitle("目录（\(chapterList.count) 章）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { showTOC = false }
                }
            }
        }
    }

    /// 找到「从目标段落开始朗读」的朗读分段索引：按顺序把分段映射到段落，第一个落在目标段落之后的分段即为起点。
    private func nearestSegmentIndex(forParagraph target: Int) -> Int? {
        guard !text.isEmpty else { return nil }
        let chunks: [String]
        if player.useAnalyzedPlayback, let a = analysis, !a.segments.isEmpty {
            chunks = a.segments.map { $0.text }
        } else {
            chunks = TextChunker().chunk(text)
        }
        guard !chunks.isEmpty else { return nil }
        var searchStart = 0
        var lastValid = 0
        for (i, c) in chunks.enumerated() {
            let key = String(c.trimmingCharacters(in: .whitespacesAndNewlines).prefix(12))
            guard !key.isEmpty else { continue }
            var found: Int? = nil
            if searchStart < paragraphs.count,
               let j = paragraphs[searchStart...].firstIndex(where: { $0.contains(key) }) {
                found = j
                searchStart = j
            } else if let j = paragraphs.firstIndex(where: { $0.contains(key) }) {
                found = j
            }
            if let f = found {
                if f >= target { return i }
                lastValid = i
            }
        }
        return lastValid
    }

    // MARK: 朗读高亮

    /// 找到当前朗读文本所在的段落：先查缓存，未命中则从上次位置向后找（朗读是顺序推进的），失败再从头找。
    /// 找到后写入缓存：同一段文本永远映射到同一段落，避免重复扫描与高亮来回跳动。
    private func paragraphIndex(for speaking: String) -> Int? {
        let key = String(speaking.trimmingCharacters(in: .whitespacesAndNewlines).prefix(12))
        guard !key.isEmpty else { return nil }
        if let cached = segmentToParagraph[key] { return cached }
        var found: Int? = nil
        if let last = highlightIndex, paragraphs.indices.contains(last), paragraphs[last].contains(key) {
            found = last
        }
        if found == nil {
            let start = (highlightIndex ?? -1) + 1
            if start < paragraphs.count,
               let i = paragraphs[start...].firstIndex(where: { $0.contains(key) }) {
                found = i
            }
        }
        if found == nil {
            found = paragraphs.firstIndex(where: { $0.contains(key) })
        }
        if let f = found { segmentToParagraph[key] = f }
        return found
    }

    /// 回到前台 / 界面恢复时立即同步高亮到当前朗读位置（不等下一次段落切换事件）。
    private func syncHighlightNow() {
        guard let speaking = player.nowSpeakingText, !speaking.isEmpty else { return }
        if let idx = paragraphIndex(for: speaking) {
            highlightIndex = idx
        }
    }

    // MARK: 解析状态灯

    private var lampColor: Color {
        guard analysis != nil else { return Color.gray }
        return analysisSource == "cloud" ? Color.green : Color.blue
    }
    private var statusText: String {
        guard analysis != nil else { return "未解析：点击「整体解析」开始分析人物与情绪。" }
        return analysisSource == "cloud" ? "云端解析成功" : "本地解析成功"
    }

    // MARK: 播放器接线（进度记忆 + 云端 TTS）

    private func configurePlayer() {
        // 进度回调：节流 3 秒保存一次，避免频繁写盘
        player.onIndexChange = { idx, analyzed in
            if Date().timeIntervalSince(lastSaveAt) > 3 {
                lastSaveAt = Date()
                store.updateProgress(documentId: item.id, segmentIndex: idx, analyzed: analyzed)
            }
        }
        // 云端 TTS 注入（未启用/未配置时返回 nil → 播放器自动用本地合成）
        player.cloudProvider = { text in
            guard settings.cloudTTSEnabled else { return nil }
            let client = CloudTTS(endpoint: settings.cloudTTSEndpoint,
                                  apiKey: settings.cloudTTSApiKey,
                                  model: settings.cloudTTSModel,
                                  voice: settings.cloudTTSVoice)
            guard client.isConfigured else { return nil }
            return try? await client.synthesize(text)
        }
        // 离线语音包注入（优先于云端）：按角色性别池轮转分配——不同角色配不同声音
        player.offlineProvider = { text, gender, characterId in
            guard settings.offlineTTSEnabled else { return nil }
            let speed = player.rate
            // 旁白（characterId 为空）且用户指定了离线旁白包 → 直接用该包合成（解决「旁白只能选系统几个声音」）
            if characterId.isEmpty, !settings.narrationOfflinePackId.isEmpty,
               OfflineTTSManager.shared.isInstalled(settings.narrationOfflinePackId) {
                return await OfflineTTSManager.shared.synthesizeWithPack(
                    text: text, packId: settings.narrationOfflinePackId,
                    sid: Int32(settings.narrationOfflineSID), speed: speed)
            }
            let maleSIDs = settings.offlineTTSMaleSIDs
                .split(separator: ",").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
            let femaleSIDs = settings.offlineTTSFemaleSIDs
                .split(separator: ",").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
            return await OfflineTTSManager.shared.synthesizeForCharacter(
                text: text, characterId: characterId, gender: gender,
                packGenders: settings.offlinePackGenders,
                maleSIDs: maleSIDs, femaleSIDs: femaleSIDs, speed: speed)
        }
        player.autoVoiceSwitch = settings.autoVoiceSwitch
        // 云端合成失败自动回退本地时，给用户一个明确提示（不再静默）
        player.onCloudFallback = {
            showToast("云端语音合成失败，本段已改用本地朗读")
        }
    }

    private func saveProgressNow() {
        let idx = player.currentSegmentIndex
        guard idx >= 0 else { return }
        store.updateProgress(documentId: item.id, segmentIndex: idx, analyzed: player.useAnalyzedPlayback)
    }

    // MARK: 播放（全局播放条 / 锁屏控件共用）

    /// 组装声音并从指定段索引开始朗读（全局播放条的「播放/继续」、锁屏控件、目录 ▶︎ 从本章朗读 共用）。
    private func startPlayback(from index: Int? = nil) {
        player.rate = settings.defaultRate
        player.autoVoiceSwitch = settings.autoVoiceSwitch

        let defaultVoice = resolveVoice(settings.defaultVoiceIdentifier)
            ?? TTSPlayer.pickVoice(preferGender: .neutral)
        player.setDefaultVoice(defaultVoice)
        player.setLanguageVoices(languageVoices(defaultVoice: defaultVoice))

        let start = index ?? pendingStart ?? 0
        let cloud = cloudEnabled

        if player.useAnalyzedPlayback, let a = analysis, !a.segments.isEmpty {
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
        pendingStart = nil   // 起点只生效一次
    }

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

    // MARK: 轻提示

    /// 解析设置页的人名过滤名单（逗号/顿号/空格/换行分隔）
    private var userBlocklist: Set<String> {
        Set(settings.nameBlocklist
            .split(whereSeparator: { "，,、 ;；\n\r\t".contains($0) })
            .map(String.init)
            .filter { !$0.isEmpty })
    }

    private func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if !Task.isCancelled { toast = nil }
        }
    }

    // MARK: 整体解析

    private enum AnalysisMode { case local, cloud }

    private func runAnalysis(mode: AnalysisMode) {
        isAnalyzing = true
        let src = text
        let useCloud = (mode == .cloud) && settings.cloudLLMEnabled && !settings.cloudLLMApiKey.isEmpty
        let apiKey = settings.cloudLLMApiKey
        let endpoint = settings.cloudLLMEndpoint
        let model = settings.cloudLLMModel
        let combinedBlocklist = userBlocklist.union(docBlacklist)
        let combinedWhitelist = Set(docWhitelist)
        analysisTask = Task {
            var result: AnalysisResult?
            var cloudFailed = false
            var cloudError = ""
            if useCloud {
                do {
                    // 优先云端（更准）；失败回退本地并提示原因
                    result = try await CloudAnalyzer().analyze(src, apiKey: apiKey,
                                                               baseURL: endpoint, model: model)
                } catch {
                    cloudFailed = true
                    cloudError = error.localizedDescription
                }
            }
            if result == nil {
                let blocklist = combinedBlocklist
                let allowlist = combinedWhitelist
                result = await Task.detached(priority: .userInitiated) {
                    CharacterAnalyzer().analyze(src, userStopwords: blocklist, userWhitelist: allowlist)
                }.value
            }
            guard !Task.isCancelled else { return }
            guard let res = result else {
                isAnalyzing = false
                analysisErrorMessage = "解析失败：本地解析与云端解析均未成功。请检查网络连接，或到设置页确认端点 / API Key / 模型是否正确后重试。"
                return
            }
            analysis = res
            analysisSource = (useCloud && !cloudFailed) ? "cloud" : "local"
            player.useAnalyzedPlayback = true
            isAnalyzing = false
            // 解析结果按文档持久化：重进/重启后结果与圆灯颜色不丢失
            store.saveAnalysis(res, source: analysisSource ?? "local", for: item.id)
            if cloudFailed {
                let brief = cloudError.count > 50 ? String(cloudError.prefix(50)) + "…" : cloudError
                showToast("云端解析失败（\(brief)），已使用本地解析结果")
            }
            showAnalysis = true
        }
    }
}

/// 正文段落行（拆出子视图，避免 SwiftUI 大表达式类型检查超时）。
private struct ParagraphRow: View {
    let text: String
    let isHighlighted: Bool
    let index: Int

    var body: some View {
        Text(text)
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHighlighted ? Color.yellow.opacity(0.30) : Color.clear)
            .cornerRadius(6)
            .textSelection(.enabled)
            .id(index)
    }
}

/// 顶部提示条：断点续读入口。
private struct BannerView: View {
    let text: String
    let onResume: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "bookmark.fill")
                .foregroundColor(.orange)
            Text(text)
                .font(.subheadline)
            Spacer()
            Button("继续朗读", action: onResume)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }
}
