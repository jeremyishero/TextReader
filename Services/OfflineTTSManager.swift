import Foundation
import AVFoundation
import CoreLogic
import ZIPFoundation
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
    @Published var errors: [String: String] = [:]       // packId → 最近一次下载失败原因

    /// 大文件下载专用会话：请求/资源超时放宽，避免 115MB 模型被默认 60s 超时掐断
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 3600
        cfg.timeoutIntervalForResource = 86400
        return URLSession(configuration: cfg)
    }()
    /// 下载线路：hf-mirror（国内直连）优先，失败自动换 huggingface 官方（有代理的用户可用）
    private static let sources = ["https://hf-mirror.com", "https://huggingface.co"]
    /// 部分 CDN 拒绝非浏览器 UA，统一带一个
    private static func request(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        return req
    }

    /// 仓库均已核实存在于 hf-mirror（不存在会导致 App 内下载必 404）
    static let packs: [VoicePackInfo] = [
        .init(id: "aishell3", repo: "csukuangfj/vits-zh-aishell3",
              displayName: "AISHELL3 · 多音色（男女都有，推荐）", gender: "多音色", sizeMB: 140),
        .init(id: "theresa", repo: "csukuangfj/vits-zh-hf-theresa",
              displayName: "Theresa · 标准女声", gender: "女声", sizeMB: 115),
        .init(id: "keqing", repo: "csukuangfj/vits-zh-hf-keqing",
              displayName: "刻晴 · 标准女声", gender: "女声", sizeMB: 115),
        .init(id: "fanchen-c", repo: "csukuangfj/vits-zh-hf-fanchen-C",
              displayName: "Fanchen-C · 音色需试听", gender: "试听确认", sizeMB: 115),
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
        errors[pack.id] = nil
        Task {
            let result = await Self.downloadPackFiles(pack: pack, destDir: packDir(pack.id)) { [weak self] p in
                Task { @MainActor in self?.progress[pack.id] = p }
            }
            await MainActor.run {
                self.downloading.remove(pack.id)
                if let msg = result {
                    self.progress[pack.id] = nil
                    self.errors[pack.id] = msg
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
    ) async -> String? {
        let fm = FileManager.default

        // 1) 文件清单：逐线路尝试
        var siblings: [[String: Any]]? = nil
        var lastErr = ""
        for src in sources {
            guard let apiURL = URL(string: src + "/api/models/" + pack.repo) else { continue }
            do {
                let (listData, resp) = try await session.data(for: request(apiURL))
                guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                    lastErr = src + " HTTP " + String((resp as? HTTPURLResponse)?.statusCode ?? -1)
                    continue
                }
                guard let obj = try? JSONSerialization.jsonObject(with: listData) as? [String: Any],
                      let s = obj["siblings"] as? [[String: Any]] else {
                    lastErr = src + " 清单解析失败"
                    continue
                }
                siblings = s
                break
            } catch {
                lastErr = src + "：" + error.localizedDescription
            }
        }
        guard let list = siblings else {
            return "所有下载线路均失败（已试 hf-mirror 与 huggingface）。最后错误：" + lastErr + "。可改用「从文件导入语音包」"
        }
        let paths = list.compactMap { $0["rfilename"] as? String }.filter { keepFile($0) }
        guard !paths.isEmpty else { return "源仓库没有可下载文件" }

        // 2) 逐文件下载（每个文件都逐线路尝试；download(to:) 落盘不占大内存）
        try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        for (i, path) in paths.enumerated() {
            var done = false
            var fileErr = ""
            for src in sources {
                guard let url = URL(string: src + "/" + pack.repo + "/resolve/main/" + path) else { continue }
                do {
                    let (tmp, dlResp) = try await session.download(for: request(url))
                    guard let http = dlResp as? HTTPURLResponse, http.statusCode == 200 else {
                        fileErr = src + " HTTP " + String((dlResp as? HTTPURLResponse)?.statusCode ?? -1)
                        continue
                    }
                    let fileURL = destDir.appendingPathComponent(path)
                    try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? fm.removeItem(at: fileURL)
                    try fm.moveItem(at: tmp, to: fileURL)
                    done = true
                    break
                } catch {
                    fileErr = src + "：" + error.localizedDescription
                }
            }
            guard done else {
                return "下载 " + path + " 失败（所有线路）。最后错误：" + fileErr + "。可改用「从文件导入语音包」"
            }
            onProgress(Double(i + 1) / Double(paths.count))
        }
        return nil
    }

    // MARK: 从文件导入语音包（.zip，内容为「语音包文件夹/」或直接文件集）

    /// 解压 zip 到对应语音包目录并校验 tokens.txt；成功返回 nil，失败返回原因。
    func importPackZip(from url: URL) -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let archive = try? Archive(url: url, accessMode: .read) else {
            return "无法读取压缩包"
        }
        // 识别包内根文件夹名（如 piper-xiaoya/model.onnx）
        var packId: String? = nil
        for entry in archive {
            let comps = entry.path.split(separator: "/")
            if comps.count > 1, comps[0] != "__MACOSX" {
                packId = String(comps[0])
                break
            }
        }
        guard let id = packId else {
            return "压缩包内需包含以语音包名命名的文件夹（如 piper-xiaoya/）"
        }
        let dest = packDir(id)
        let prefix = id + "/"
        for entry in archive where entry.path.hasPrefix(prefix) {
            let rel = String(entry.path.dropFirst(prefix.count))
            if rel.isEmpty { continue }
            let fileURL = dest.appendingPathComponent(rel)
            if entry.type == .directory {
                try? fm.createDirectory(at: fileURL, withIntermediateDirectories: true)
                continue
            }
            try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: fileURL)
            do {
                _ = try archive.extract(entry, to: fileURL)
            } catch {
                return "解压 " + rel + " 失败：" + error.localizedDescription
            }
        }
        guard fm.fileExists(atPath: dest.appendingPathComponent("tokens.txt").path) else {
            try? fm.removeItem(at: dest)
            return "压缩包内缺少 tokens.txt，不是有效的语音包"
        }
        return nil
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
    /// 多音色包：按角色性别自动选 sid（maleSID/femaleSID）；单音色包忽略 sid（固定 0）。
    func synthesize(text: String, packId: String, gender: Gender,
                    maleSID: Int32, femaleSID: Int32, speed: Float) async -> Data? {
        guard !text.isEmpty, isInstalled(packId) else { return nil }
        let dir = packDir(packId).path
        return await withCheckedContinuation { cont in
            engineQueue.async { [weak self] in
                guard let self else { cont.resume(returning: nil); return }
                guard let tts = self.loadEngine(packId: packId, dir: dir) else {
                    cont.resume(returning: nil); return
                }
                let sid: Int32 = SherpaOnnxOfflineTtsNumSpeakers(tts) > 1
                    ? (gender == .male ? maleSID : femaleSID)
                    : 0
                let data = self.engineSynthesize(text: text, packId: packId, dir: dir, tts: tts, sid: sid, speed: speed)
                cont.resume(returning: data)
            }
        }
    }

    private func engineSynthesize(text: String, packId: String, dir: String,
                                  tts: OpaquePointer, sid: Int32, speed: Float) -> Data? {
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
        vits.model = UnsafePointer(strdup(dir + "/" + modelRel))
        vits.tokens = UnsafePointer(strdup(dir + "/" + tokensRel))
        if let lexiconRel = firstFile(matching: { $0 == "lexicon.txt" || $0.hasPrefix("lexicon") && $0.hasSuffix(".txt") }) {
            vits.lexicon = UnsafePointer(strdup(dir + "/" + lexiconRel))
        }
        if let espeakRel = firstFile(matching: { $0 == "espeak-ng-data" && Self.isDirectory(dir + "/" + $0) }) {
            vits.data_dir = UnsafePointer(strdup(dir + "/" + espeakRel))
        }
        if let dictRel = firstFile(matching: { $0 == "dict" && Self.isDirectory(dir + "/" + $0) }) {
            vits.dict_dir = UnsafePointer(strdup(dir + "/" + dictRel))
        }
        vits.noise_scale = 0.667
        vits.noise_scale_w = 0.8
        vits.length_scale = 1.0

        var model = SherpaOnnxOfflineTtsModelConfig()
        model.vits = vits
        model.num_threads = 2
        model.debug = 0
        model.provider = UnsafePointer(strdup("cpu"))

        var config = SherpaOnnxOfflineTtsConfig()
        config.model = model
        let fsts = ["date.fst", "number.fst"].compactMap { fm.fileExists(atPath: dir + "/" + $0) ? dir + "/" + $0 : nil }
        if !fsts.isEmpty { config.rule_fsts = UnsafePointer(strdup(fsts.joined(separator: ","))) }
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
