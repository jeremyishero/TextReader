import Foundation
import AVFoundation
import sherpa_capi

/// 可下载的离线语音包（模型来自 sherpa-onnx 社区，HuggingFace 托管，国内经 hf-mirror.com 镜像下载）。
/// 代码许可 Apache-2.0；各模型许可见其仓库说明，均为可自由使用的开放模型。
struct VoicePackInfo: Identifiable, Equatable {
    let id: String          // 本地目录名
    let repo: String        // HuggingFace 仓库（csukuangfj/…）
    let displayName: String
    let gender: String
    let sizeMB: Int
}

/// 离线 TTS 管理器：
/// - 下载：查询 hf-mirror API 拿文件清单，逐文件下载到 Documents/VoicePacks/<id>/（保留相对路径）；
/// - 合成：SherpaOnnx C API 加载 VITS 模型 → generate → 内存写 WAV → Data 交给播放器。
/// 引擎访问全部经 engineQueue 串行化；UI 状态（progress/downloading）只在主线程改。
final class OfflineTTSManager: ObservableObject {
    static let shared = OfflineTTSManager()

    @Published var downloading: Set<String> = []
    @Published var progress: [String: Double] = [:]     // packId → 0~1

    static let packs: [VoicePackInfo] = [
        .init(id: "piper-xiaoya", repo: "csukuangfj/vits-piper-zh_CN-xiao_ya-medium-int8",
              displayName: "小雅 · 轻量极速", gender: "女声", sizeMB: 14),
        .init(id: "theresa", repo: "csukuangfj/vits-zh-hf-theresa",
              displayName: "Theresa · 标准女声", gender: "女声", sizeMB: 115),
        .init(id: "keqing", repo: "csukuangfj/vits-zh-hf-keqing",
              displayName: "刻晴 · 标准女声", gender: "女声", sizeMB: 115),
        .init(id: "aishell3", repo: "csukuangfj/vits-icefall-zh-aishell3",
              displayName: "AISHELL3 · 多音色（男女都有）", gender: "多音色", sizeMB: 30),
    ]

    private let fm = FileManager.default
    private let engineQueue = DispatchQueue(label: "offline.tts.engine")   // 引擎加载/合成串行
    private var engines: [String: OpaquePointer] = [:]

    private var packsRoot: URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoicePacks", isDirectory: true)
    }
    func packDir(_ id: String) -> URL {
        packsRoot.appendingPathComponent(id, isDirectory: true)
    }
    func isInstalled(_ id: String) -> Bool {
        fm.fileExists(atPath: packDir(id).appendingPathComponent("tokens.txt").path)
    }

    // MARK: 下载

    func download(_ pack: VoicePackInfo) {
        guard !downloading.contains(pack.id) else { return }
        downloading.insert(pack.id)
        progress[pack.id] = 0
        Task {
            let ok = await Self.downloadPackFiles(pack: pack, destDir: packDir(pack.id)) { [weak self] p in
                Task { @MainActor in self?.progress[pack.id] = p }
            }
            await MainActor.run {
                self.downloading.remove(pack.id)
                if !ok {
                    self.progress[pack.id] = nil
                    // 清掉半成品，避免误判已安装
                    try? self.fm.removeItem(at: self.packDir(pack.id))
                }
            }
        }
    }

    func deletePack(_ id: String) {
        engineQueue.sync {
            if let tts = engines.removeValue(forKey: id) {
                SherpaOnnxDestroyOfflineTts(tts)
            }
        }
        try? fm.removeItem(at: packDir(id))
    }

    /// 逐文件下载（保留仓库内相对路径）。
    private static func downloadPackFiles(
        pack: VoicePackInfo, destDir: URL,
        onProgress: @escaping (Double) -> Void
    ) async -> Bool {
        let fm = FileManager.default
        // 1) 文件清单（经 hf-mirror API；HF 主站在国内不可达）
        guard let apiURL = URL(string: "https://hf-mirror.com/api/models/\(pack.repo)"),
              let (listData, _) = try? await URLSession.shared.data(from: apiURL),
              let obj = try? JSONSerialization.jsonObject(with: listData) as? [String: Any],
              let siblings = obj["siblings"] as? [[String: Any]] else { return false }
        let paths = siblings.compactMap { $0["rfilename"] as? String }.filter { Self.keepFile($0) }
        guard !paths.isEmpty else { return false }

        // 2) 逐文件下载（保留相对路径）
        try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        for (i, path) in paths.enumerated() {
            guard let url = URL(string: "https://hf-mirror.com/\(pack.repo)/resolve/main/\(path)") else { return false }
            guard let (data, resp) = try? await URLSession.shared.data(from: url),
                  let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return false }
            let fileURL = destDir.appendingPathComponent(path)
            try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try data.write(to: fileURL, options: .atomic)
            } catch { return false }
            onProgress(Double(i + 1) / Double(paths.count))
        }
        return true
    }

    /// 该下载仓库里的哪些文件（跳过文档/脚本/测试音频/压缩包本身）。
    private static func keepFile(_ path: String) -> Bool {
        let last = (path as NSString).lastPathComponent
        if path.hasPrefix("test_wavs") || path.hasPrefix(".git") { return false }
        if last.hasSuffix(".md") || last == ".gitattributes" { return false }
        if last.hasSuffix(".py") || last.hasSuffix(".sh") || last.hasSuffix(".tar.bz2") { return false }
        return true
    }

    // MARK: 合成

    /// 合成一段文本 → WAV Data。引擎按包缓存、串行加载；失败返回 nil（播放器自动回退云端/本地）。
    func synthesize(text: String, packId: String, sid: Int32, speed: Float) async -> Data? {
        guard !text.isEmpty, isInstalled(packId) else { return nil }
        let dir = packDir(packId).path
        return await withCheckedContinuation { cont in
            engineQueue.async { [weak self] in
                guard let self else { cont.resume(returning: nil); return }
                let data = self.engineSynthesize(text: text, packId: packId, dir: dir, sid: sid, speed: speed)
                cont.resume(returning: data)
            }
        }
    }

    private func engineSynthesize(text: String, packId: String, dir: String, sid: Int32, speed: Float) -> Data? {
        guard let tts = loadEngine(packId: packId, dir: dir) else { return nil }
        let audio = SherpaOnnxOfflineTtsGenerate(tts, text, sid, speed)
        guard let audio, audio.pointee.n > 0 else {
            if let audio { SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio) }
            return nil
        }
        let n = audio.pointee.n
        let sr = audio.pointee.sample_rate
        var buffer = Data(count: Int(SherpaOnnxWaveFileSize(n)))
        var ok = false
        buffer.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) {
                SherpaOnnxWriteWaveToBuffer(audio.pointee.samples, n, sr, base)
                ok = true
            }
        }
        SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio)
        return ok ? buffer : nil
    }

    /// 从包目录探测文件布局（兼容 piper / hf-theresa / icefall-aishell3 等不同结构）并加载引擎。
    private func loadEngine(packId: String, dir: String) -> OpaquePointer? {
        if let cached = engines[packId] { return cached }
        let fm = FileManager.default

        func firstFile(matching predicate: (String) -> Bool) -> String? {
            let children = (fm.subpaths(atPath: dir) ?? []).filter { predicate($0) }
            return children.sorted().first
        }
        guard let modelRel = firstFile(matching: { $0.hasSuffix(".onnx") }),
              let tokensRel = firstFile(matching: { $0 == "tokens.txt" }) else { return nil }

        var vits = SherpaOnnxOfflineTtsVitsModelConfig()
        vits.model = strdup(dir + "/" + modelRel)
        vits.tokens = strdup(dir + "/" + tokensRel)
        if let lexiconRel = firstFile(matching: { $0 == "lexicon.txt" || $0.hasPrefix("lexicon") && $0.hasSuffix(".txt") }) {
            vits.lexicon = strdup(dir + "/" + lexiconRel)
        }
        if let espeakRel = firstFile(matching: { $0 == "espeak-ng-data" && Self.isDirectory(dir + "/" + $0) }) {
            vits.data_dir = strdup(dir + "/" + espeakRel)
        }
        if let dictRel = firstFile(matching: { $0 == "dict" && Self.isDirectory(dir + "/" + $0) }) {
            vits.dict_dir = strdup(dir + "/" + dictRel)
        }
        vits.noise_scale = 0.667
        vits.noise_scale_w = 0.8
        vits.length_scale = 1.0

        var model = SherpaOnnxOfflineTtsModelConfig()
        model.vits = vits
        model.num_threads = 2
        model.debug = 0
        model.provider = strdup("cpu")

        var config = SherpaOnnxOfflineTtsConfig()
        config.model = model
        let fsts = ["date.fst", "number.fst"].compactMap { fm.fileExists(atPath: dir + "/" + $0) ? dir + "/" + $0 : nil }
        if !fsts.isEmpty { config.rule_fsts = strdup(fsts.joined(separator: ",")) }
        config.max_num_sentences = 2

        guard let tts = SherpaOnnxCreateOfflineTts(&config) else { return nil }
        engines[packId] = tts
        return tts
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}
