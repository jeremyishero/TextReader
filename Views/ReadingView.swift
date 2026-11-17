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
    @State private var lastVisibleParagraph: Int? = nil        // 最近一次阅读所在段落（目录跳转 / 高亮）
    @State private var restoreParagraph: Int? = nil            // 重进时要滚回的段落
    @State private var pendingStartAnalyzed: Bool? = nil       // 断点续读保存时的分声模式
    @State private var entryProgress: ReadingProgress? = nil   // 进入页面时的进度快照（Banner 只显示一次）

    /// item 是进入页面时的值快照；进度写入 store 后不会回写到 item，
    /// 因此统一从 store 取最新进度，保证续读用的是刚保存的值。
    private var currentProgress: ReadingProgress? {
        store.documents.first { $0.id == item.id }?.progress
    }

    var body: some View {
        VStack(spacing: 0) {
            if let p = entryProgress {
                BannerView(text: "上次读到第 \(p.segmentIndex + 1) 段") {
                    pendingStart = p.segmentIndex
                    pendingStartAnalyzed = p.analyzed   // 按保存时的分声模式还原分段体系
                    entryProgress = nil                // 用过即隐藏，避免朗读推进时反复刷新
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
                                    // 手动滚动阅读时记录可见段落；朗读中由 onReceive 的高亮链路负责，避免互相覆盖
                                    .onAppear {
                                        if !player.isPlaying { lastVisibleParagraph = idx }
                                    }
                            }
                        }
                        .padding()
                    }
                    .onReceive(player.$nowSpeakingText) { speaking in
                        guard let speaking, !speaking.isEmpty else { return }
                        let idx = paragraphIndex(for: speaking)
                        if let idx, idx != highlightIndex {
                            highlightIndex = idx
                            lastVisibleParagraph = idx   // 朗读位置也是阅读位置
                            withAnimation {
                                proxy.scrollTo(idx, anchor: .center)
                            }
                        }
                    }
                    // 重进 / 重启 APP 后，滚回上次阅读的段落（不依赖是否曾点过播放）。
                    // onAppear 覆盖「loadText 先跑完」；onChange 覆盖「.task 稍晚才设置 restoreParagraph」。
                    // 两者都用完即置 nil，幂等，不会重复滚动。
                    .onAppear { restoreScrollIfNeeded(proxy: proxy) }
                    .onChange(of: restoreParagraph) { _ in restoreScrollIfNeeded(proxy: proxy) }
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
                // AnalysisView 新增了 @EnvironmentObject settings；sheet 内显式注入，避免环境对象未传播时崩溃
                .environmentObject(settings)
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
            // 仅记录「当前显示的是哪本书的阅读页」，不再在这里改写 activeTitle——
            // 否则只是「看一眼」另一本在播的书，底部的播放条标题就会被改成这本书，
            // 造成「好像在读这本书」的错觉。activeTitle 只在真正起播本书时才设置。
            player.readingViewBookId = item.id.uuidString
            player.openTOCHandler = { showTOC = true }
            player.startPlaybackHandler = { idx in self.startPlayback(from: idx) }
        }
        .onChange(of: scenePhase) { phase in
            // 从后台/锁屏回到前台时，立即把高亮同步到当前朗读位置
            if phase == .active {
                syncHighlightNow()
            } else {
                // 进后台/失活：系统可能直接杀掉 App，onDisappear 不保证触发，这里先落盘
                saveProgressNow()
            }
        }
        .onDisappear {
            saveProgressNow()
            player.onIndexChange = nil
            player.onCloudFallback = nil
            player.startPlaybackHandler = nil
            player.openTOCHandler = nil
            // 离开阅读页时清掉「当前显示的书」标记；仅当仍指向本书时才清，避免覆盖新页面的设置
            if player.readingViewBookId == item.id.uuidString { player.readingViewBookId = nil }
        }
    }

    // MARK: 工具栏与反馈浮层

    @ToolbarContentBuilder
    private var readerToolbar: some ToolbarContent {
        // 从当前阅读位置起播：看了一会儿再听时，不必从头/断点开始
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                playFromCurrentPage()
            } label: {
                Label("从当前页听", systemImage: "playpause.circle")
            }
            .disabled(text.isEmpty)
            .accessibilityLabel("从当前页听")
        }
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
        // 重进时准备滚回上次阅读的段落（优先阅读段落索引；旧档无该字段时退回朗读段映射）
        let progressSnapshot = currentProgress
        entryProgress = progressSnapshot
        if let p = progressSnapshot {
            if let para = p.paragraphIndex, paragraphs.indices.contains(para) {
                restoreParagraph = para
            } else if let para = paragraphForSegmentIndex(p.segmentIndex, analyzed: p.analyzed),
                      paragraphs.indices.contains(para) {
                restoreParagraph = para
            }
        }
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

    /// 滚回上次阅读段落（重进 / 重启后）。用完即清空，保证只恢复一次。
    private func restoreScrollIfNeeded(proxy: ScrollViewProxy) {
        guard let target = restoreParagraph,
              paragraphs.indices.contains(target) else { return }
        let t = target
        highlightIndex = t
        lastVisibleParagraph = t
        restoreParagraph = nil
        // 延迟一拍，等 LazyVStack 完成布局，确保远处 id 可被 scrollTo 命中
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            withAnimation { proxy.scrollTo(t, anchor: .top) }
        }
    }

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
                        // 视图跳转：滚动到该章节段落，并立即把「阅读位置」落盘
                        showTOC = false
                        highlightIndex = ch.index
                        lastVisibleParagraph = ch.index
                        let seg = nearestSegmentIndex(forParagraph: ch.index) ?? 0
                        store.updateReadingPosition(documentId: item.id,
                                                    paragraphIndex: ch.index,
                                                    segmentIndex: seg,
                                                    analyzed: player.useAnalyzedPlayback)
                        withAnimation {
                            proxy.scrollTo(ch.index, anchor: .top)
                        }
                        showToast("已定位到「\(ch.title)」")
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

    /// 旧档只有朗读分段索引、没有阅读段落索引：按保存时的分声模式取对应分段文本，反查所在段落。
    private func paragraphForSegmentIndex(_ idx: Int, analyzed: Bool) -> Int? {
        guard idx >= 0 else { return nil }
        let texts: [String]
        if analyzed, let a = analysis, !a.segments.isEmpty {
            texts = a.segments.map { $0.text }
        } else {
            texts = TextChunker().chunk(text)
        }
        guard texts.indices.contains(idx) else { return nil }
        let key = String(texts[idx].trimmingCharacters(in: .whitespacesAndNewlines).prefix(12))
        guard !key.isEmpty else { return nil }
        return paragraphs.firstIndex { $0.contains(key) }
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
        // 进度回调：节流 3 秒保存一次，避免频繁写盘。
        // 朗读段索引与阅读段落索引一起落盘，保证两条链路始终一致。
        player.onIndexChange = { idx, analyzed in
            if Date().timeIntervalSince(lastSaveAt) > 3 {
                lastSaveAt = Date()
                store.updateProgress(documentId: item.id, segmentIndex: idx, analyzed: analyzed,
                                     paragraphIndex: lastVisibleParagraph ?? highlightIndex)
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
        // 手工指定离线包的合成通道：闭包只接收值类型参数，不捕获 player/settings。
        // 具体由 TTSPlayer.buildPrepared 在 @MainActor 上下文按角色查表后调用。
        player.manualOfflineSynth = { text, packId, sid, speed in
            guard OfflineTTSManager.shared.isInstalled(packId) else { return nil }
            return await OfflineTTSManager.shared.synthesizeWithPack(
                text: text, packId: packId, sid: sid, speed: speed)
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
        // 段落/章节停顿（设置页可调；改动后从下一次起播生效）
        player.paragraphPause = settings.paragraphPause
        player.chapterPause = settings.chapterPause
        // 云端合成失败自动回退本地时，给用户一个明确提示（不再静默）
        player.onCloudFallback = {
            showToast("云端语音合成失败，本段已改用本地朗读")
        }
    }

    private func saveProgressNow() {
        let idx = player.currentSegmentIndex
        let para = lastVisibleParagraph ?? highlightIndex
        if idx >= 0 {
            // 朗读中：朗读段索引为准，同时带上阅读段落
            store.updateProgress(documentId: item.id, segmentIndex: idx,
                                 analyzed: player.useAnalyzedPlayback, paragraphIndex: para)
        } else if let para {
            // 纯阅读 / 停止后从未朗读：朗读段索引是 -1，也必须把阅读位置落盘。
            // 已有朗读断点时保留原 segmentIndex / analyzed，只更新段落索引。
            let prev = currentProgress
            let seg = prev?.segmentIndex ?? (nearestSegmentIndex(forParagraph: para) ?? 0)
            let analyzed = prev?.analyzed ?? player.useAnalyzedPlayback
            store.updateReadingPosition(documentId: item.id, paragraphIndex: para,
                                        segmentIndex: seg, analyzed: analyzed)
        }
    }

    // MARK: 播放（全局播放条 / 锁屏控件共用）

    /// 从当前阅读所在段落开始朗读。优先用最近可见段落（手动滚动/朗读位置都会被记录），
    /// 再映射到当前分段体系（普通分块 or 分声段）的段索引；映射失败则从 0 起播。
    private func playFromCurrentPage() {
        let para = highlightIndex ?? lastVisibleParagraph ?? 0
        let seg = nearestSegmentIndex(forParagraph: para) ?? 0
        // 显式起点：按当前是否启用分声来定模式，不沿用旧进度里保存的模式
        pendingStartAnalyzed = player.useAnalyzedPlayback
        pendingStart = seg
        startPlayback(from: seg)
        showToast("从当前页（第 \(para + 1) 段）开始朗读")
    }

    /// 组装声音并从指定段索引开始朗读（全局播放条的「播放/继续」、锁屏控件、目录 ▶︎ 从本章朗读 共用）。
    /// 关键：断点续读必须按「保存时的分声模式」还原分段体系，否则普通分块索引会被套到分声段上（或反之），位置错乱。
    private func startPlayback(from index: Int? = nil) {
        player.rate = settings.defaultRate
        player.autoVoiceSwitch = settings.autoVoiceSwitch

        let defaultVoice = resolveVoice(settings.defaultVoiceIdentifier)
            ?? TTSPlayer.pickVoice(preferGender: .neutral)
        player.setDefaultVoice(defaultVoice)
        player.setLanguageVoices(languageVoices(defaultVoice: defaultVoice))

        // 每次起播都重建手工指定映射，避免换文档/关闭分声后残留上一本的配置
        player.manualOfflinePacks = [:]
        player.manualSystemVoiceIds = []

        let saved = currentProgress
        // 模式优先级：Banner 显式指定的保存模式 > 无起点时按进度里的模式 > 目录 ▶︎ 等显式起点按当前开关
        if let explicitMode = pendingStartAnalyzed {
            player.useAnalyzedPlayback = explicitMode
        } else if index == nil, let s = saved {
            player.useAnalyzedPlayback = s.analyzed
        }
        let wantAnalyzed = player.useAnalyzedPlayback
        let canAnalyze: Bool = {
            guard wantAnalyzed, let a = analysis, !a.segments.isEmpty else { return false }
            return true
        }()
        // 只在普通模式下才做全量分块，分声模式直接用已缓存的解析结果，避免大文件每次起播都重切一遍
        let chunks: [String] = canAnalyze ? [] : TextChunker().chunk(text)
        let total = canAnalyze ? (analysis?.segments.count ?? 0) : chunks.count
        guard total > 0 else {
            pendingStart = nil
            pendingStartAnalyzed = nil
            return
        }

        let base = index ?? pendingStart ?? saved?.segmentIndex ?? 0
        // 模式与保存时不一致（典型：旧档存的是分声段，但重进后解析缓存暂不可用）时，
        // 用阅读段落重新映射，避免把另一套体系的索引直接套过来导致「跳到书尾/开头」。
        var start = base
        if let s = saved, s.analyzed != canAnalyze,
           let para = s.paragraphIndex,
           let mapped = nearestSegmentIndex(forParagraph: para) {
            start = mapped
        }
        start = max(0, min(start, total - 1))   // 索引范围校验，杜绝越界被静默钳到末尾

        // 真正起播本书时才更新「当前在朗读的标题 / 文档 id」——
        // 这样底部控制条只在本书确实是当前朗读对象时才显示完整控制，
        // 否则（别的书在播、只是切进来看一眼）只显示「播放本书」。
        player.activeTitle = item.name
        player.currentDocumentId = item.id.uuidString

        let cloud = cloudEnabled

        if canAnalyze, let a = analysis {
            // 把「角色称呼 → 声音选择」按 role.id 拆成两条通道：
            //   ① 离线包编码 → manualOfflinePacks（offlineProvider 直连该包）
            //   ② 系统声 identifier → roleVoices + manualSystemVoiceIds（跳过离线/云端）
            // 未指定的角色保持自动分配。
            var manualOffline: [String: (packId: String, sid: Int32)] = [:]
            var manualSystem: Set<String> = []
            for role in a.roles {
                guard let choice = voiceOverrides[role.canonicalName] else { continue }
                if let preset = VoicePresetProvider.byEncoded(choice) {
                    // 48 音色预设：还原为 (packId, sid) 直连该包该说话人
                    manualOffline[role.id] = (preset.packId, preset.sid)
                } else if let offline = VoiceChoice.decode(choice) {
                    manualOffline[role.id] = offline
                } else if let v = AVSpeechSynthesisVoice(identifier: choice), TTSPlayer.isAllowedSystemVoice(v) {
                    manualSystem.insert(role.id)
                }
            }
            player.manualOfflinePacks = manualOffline
            player.manualSystemVoiceIds = manualSystem

            // 先按性别池自动分配（含性别音高补偿），再套用本文档的手动声音配置（按角色称呼匹配，仅对本文档生效）
            let assign = TTSPlayer.assignVoicesAndPitches(roles: a.roles)
            var map: [String: AVSpeechSynthesisVoice] = [:]
            var pitches: [String: Float] = [:]
            for role in a.roles {
                if let identifier = voiceOverrides[role.canonicalName],
                   let v = AVSpeechSynthesisVoice(identifier: identifier),
                   TTSPlayer.isAllowedSystemVoice(v) {
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
            player.playPlain(chunks, startIndex: start, cloud: cloud)
        }
        pendingStart = nil            // 起点只生效一次
        pendingStartAnalyzed = nil
    }

    private func resolveVoice(_ identifier: String?) -> AVSpeechSynthesisVoice? {
        guard let v = identifier.flatMap({ AVSpeechSynthesisVoice(identifier: $0) }) else { return nil }
        // 白名单：旧配置里存过的其它 zh-CN 系统声 identifier 一律忽略（念中文口音生硬），
        // 调用方会经 ?? 链回落到 Tingting。
        guard TTSPlayer.isAllowedSystemVoice(v) else { return nil }
        return v
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
