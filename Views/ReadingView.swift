import SwiftUI
import CoreLogic

struct ReadingView: View {
    @EnvironmentObject var store: DocumentStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var player: TTSPlayer
    let item: DocumentItem

    @State private var text: String = ""
    @State private var analysis: AnalysisResult?
    @State private var isAnalyzing = false
    @State private var showAnalysis = false
    @State private var useAnalyzed = false
    @State private var pendingStart: Int? = nil   // 断点续读起始段
    @State private var lastSaveAt = Date.distantPast
    @State private var analysisErrorMessage: String?
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            if let p = item.progress {
                BannerView(text: "上次读到第 \(p.segmentIndex + 1) 段") {
                    pendingStart = p.segmentIndex
                }
            }
            ScrollView {
                Text(text.isEmpty ? "（未能提取到文本，可能是扫描版 PDF 或空文件）" : text)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            Divider()
            PlayerBar(text: text, analysis: analysis, useAnalyzed: $useAnalyzed, startIndex: $pendingStart)
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("整体解析") { runAnalysis() }
                    .disabled(isAnalyzing || text.isEmpty)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("解析结果") { showAnalysis = true }
                    .disabled(analysis == nil)
            }
        }
        .overlay {
            // 规范：解析耗时可能超过 1 秒 → 全屏进度框；静默回退/成功提示 → 轻提示；失败 → Alert
            if isAnalyzing {
                BusyHUD(title: "正在解析人物与情绪，请稍候…")
            } else if let toast {
                ToastView(text: toast, isErrorStyle: true)
            }
        }
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
        .sheet(isPresented: $showAnalysis) {
            if let a = analysis { AnalysisView(analysis: a) }
        }
        .task { loadText() }
        .onAppear { configurePlayer() }
        .onDisappear {
            saveProgressNow()
            player.onIndexChange = nil
            player.onCloudFallback = nil
        }
    }

    // MARK: 轻提示

    private func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if !Task.isCancelled { toast = nil }
        }
    }

    private func loadText() {
        if let t = store.text(for: item) { text = t }
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
        player.autoVoiceSwitch = settings.autoVoiceSwitch
        // 云端合成失败自动回退本地时，给用户一个明确提示（不再静默）
        player.onCloudFallback = {
            showToast("云端语音合成失败，本段已改用本地朗读")
        }
    }

    private func saveProgressNow() {
        let idx = player.currentSegmentIndex
        guard idx >= 0 else { return }
        store.updateProgress(documentId: item.id, segmentIndex: idx, analyzed: useAnalyzed)
    }

    // MARK: 整体解析

    private func runAnalysis() {
        isAnalyzing = true
        let src = text
        let useCloud = settings.cloudLLMEnabled && !settings.cloudLLMApiKey.isEmpty
        let apiKey = settings.cloudLLMApiKey
        Task {
            var result: AnalysisResult?
            var cloudFailed = false
            if useCloud {
                do {
                    // 优先云端（更准）；失败回退本地并提示
                    result = try await CloudAnalyzer().analyze(src, apiKey: apiKey)
                } catch {
                    cloudFailed = true
                }
            }
            if result == nil {
                result = await Task.detached(priority: .userInitiated) {
                    CharacterAnalyzer().analyze(src)
                }.value
            }
            guard let res = result else {
                isAnalyzing = false
                analysisErrorMessage = "解析失败：本地解析与云端解析均未成功。请检查网络连接，或到设置页确认云端 API Key 是否有效后重试。"
                return
            }
            analysis = res
            useAnalyzed = true
            isAnalyzing = false
            if cloudFailed {
                showToast("云端解析失败，已使用本地解析结果")
            }
            showAnalysis = true
        }
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
