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
    /// 磁盘安装状态版本号：删除/下载完成/导入成功后 +1，驱动 SwiftUI 重绘各行（isInstalled 是磁盘查询，本身不发布变化）
    @Published var revision: Int = 0

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
        .init(id: "theresa", repo: "csukuangfj/vits-zh-hf-theresa",
              displayName: "Theresa · 女声", gender: "女声", sizeMB: 115),
        .init(id: "keqing", repo: "csukuangfj/vits-zh-hf-keqing",
              displayName: "刻晴 · 女声", gender: "女声", sizeMB: 115),
        .init(id: "eula", repo: "csukuangfj/vits-zh-hf-eula",
              displayName: "优菈 · 女声", gender: "女声", sizeMB: 115),
        .init(id: "bronya", repo: "csukuangfj/vits-zh-hf-bronya",
              displayName: "布洛妮娅 · 女声", gender: "女声", sizeMB: 115),
        .init(id: "echo", repo: "csukuangfj/vits-zh-hf-echo",
              displayName: "Echo · 女声", gender: "女声", sizeMB: 115),
        .init(id: "melo", repo: "csukuangfj/vits-melo-tts-zh_en",
              displayName: "Melo · 女声（中英混读）", gender: "女声", sizeMB: 163),
        .init(id: "zenyatta", repo: "csukuangfj/vits-zh-hf-zenyatta",
              displayName: "禅雅塔 · 男声（候选）", gender: "男声", sizeMB: 115),
        .init(id: "fanchen-c", repo: "csukuangfj/vits-zh-hf-fanchen-C",
              displayName: "Fanchen-C · 男声（候选）", gender: "男声", sizeMB: 115),
        .init(id: "fanchen-unity", repo: "csukuangfj/vits-zh-hf-fanchen-unity",
              displayName: "Fanchen-unity · 试听确认", gender: "试听确认", sizeMB: 115),
        .init(id: "aishell3", repo: "",
              displayName: "AISHELL3 · 多音色 174 人（仅 zip 导入）", gender: "多音色", sizeMB: 30),
        .init(id: "chaowen", repo: "",
              displayName: "朝闻 · 试听确认（仅 zip 导入）", gender: "试听确认", sizeMB: 14),
        .init(id: "abyssinvoker", repo: "csukuangfj/vits-zh-hf-abyssinvoker",
              displayName: "深渊咏者 · 男声（候选）", gender: "男声", sizeMB: 115),
        .init(id: "doom", repo: "csukuangfj/vits-zh-hf-doom",
              displayName: "Doom · 试听确认", gender: "试听确认", sizeMB: 115),
        .init(id: "zhihuilaozhe", repo: "csukuangfj/vits-zh-hf-fanchen-ZhiHuiLaoZhe",
              displayName: "智慧老者 · 男声长者（候选）", gender: "男声", sizeMB: 114),
        .init(id: "zh-ll", repo: "csukuangfj/sherpa-onnx-vits-zh-ll",
              displayName: "LL · 试听确认", gender: "试听确认", sizeMB: 113),
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
        // tokens.txt 可能在包根目录或 data/ 等子目录（icefall aishell3 布局）
        let subpaths = (try? fm.subpathsOfDirectory(atPath: packDir(id).path)) ?? []
        return subpaths.contains { ($0 as NSString).lastPathComponent == "tokens.txt" }
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
                } else {
                    self.progress[pack.id] = 1
                }
                // 下载结束（成功或失败）都刷新一次行的安装状态
                self.revision += 1
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
        // 磁盘已删除，通知 SwiftUI 立即重绘（否则要退出设置页再进入才更新）
        revision += 1
        errors[id] = nil
        progress[id] = nil
    }

    /// 逐文件下载（保留仓库内相对路径）。
    private static func downloadPackFiles(
        pack: VoicePackInfo, destDir: URL,
        onProgress: @escaping (Double) -> Void
    ) async -> String? {
        let fm = FileManager.default
        // 仅支持从文件导入的包（repo 为空）：避免在 App 内误拉错误资源
        guard !pack.repo.isEmpty else {
            return "该语音包仅支持「从文件导入语音包(.zip)」，请用设置里的导入按钮"
        }

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
        // 导入成功：立即刷新语音包列表（安装状态是磁盘查询，需显式触发重绘）
        revision += 1
        errors[id] = nil
        return nil
    }

    /// 该下载仓库里的哪些文件（跳过文档/脚本/测试音频/压缩包本身）。
    private static func keepFile(_ path: String) -> Bool {
        let last = (path as NSString).lastPathComponent
        if path.hasPrefix("test_wavs") || path.hasPrefix(".git") { return false }
        if last.hasSuffix(".md") || last == ".gitattributes" { return false }
        if last.hasSuffix(".py") || last.hasSuffix(".sh") || last.hasSuffix(".tar.bz2") { return false }
        // 训练权重/日志/可视化数据对推理无用，体积可能上 GB，必须排除
        if last.hasSuffix(".pt") || last.hasSuffix(".pth") || last.hasSuffix(".onnx.json") { return false }
        if path.contains("/log/") || path.contains("tensorboard") || last.hasPrefix("events.out.tfevents") { return false }
        return true
    }

    // MARK: 合成

    /// 试听用：指定包 + 指定编号合成（单音色包自动忽略编号）
    func synthesizePreview(text: String, packId: String, sid: Int32, speed: Float) async -> Data? {
        guard !text.isEmpty, isInstalled(packId) else { return nil }
        let dir = packDir(packId).path
        return await withCheckedContinuation { cont in
            engineQueue.async { [weak self] in
                guard let self else { cont.resume(returning: nil); return }
                guard let tts = self.loadEngine(packId: packId, dir: dir) else {
                    cont.resume(returning: nil); return
                }
                let actual: Int32 = SherpaOnnxOfflineTtsNumSpeakers(tts) > 1 ? sid : 0
                let data = self.engineSynthesize(text: text, packId: packId, dir: dir, tts: tts, sid: actual, speed: speed)
                cont.resume(returning: data)
            }
        }
    }

    /// 角色分配缓存：characterId → (packId, sid)，同一角色（含别名）全程固定同一声音
    private var roleAssignments: [String: (packId: String, sid: Int32)] = [:]
    /// 同性别池轮转游标（保证不同角色分到不同声音）
    private var rotationCursor: [String: Int] = [:]

    /// 角色合成入口：按性别池轮转分配——单音色性别包池 → 多音色包(编号列表) → nil（回退云端/本地）。
    /// 同一角色固定分配；不同角色依次取池内不同包/不同编号，实现「多个男角色不同男声、多个女角色不同女声」。
    func synthesizeForCharacter(text: String, characterId: String, gender: Gender,
                                packGenders: [String: String],
                                maleSIDs: [Int32], femaleSIDs: [Int32],
                                speed: Float) async -> Data? {
        guard !text.isEmpty else { return nil }
        return await withCheckedContinuation { cont in
            engineQueue.async { [weak self] in
                guard let self else { cont.resume(returning: nil); return }
                let plan = self.assign(characterId: characterId, gender: gender,
                                       packGenders: packGenders,
                                       maleSIDs: maleSIDs, femaleSIDs: femaleSIDs)
                guard let (packId, sid) = plan, self.isInstalled(packId) else {
                    cont.resume(returning: nil); return
                }
                let dir = self.packDir(packId).path
                guard let tts = self.loadEngine(packId: packId, dir: dir) else {
                    cont.resume(returning: nil); return
                }
                let data = self.engineSynthesize(text: text, packId: packId, dir: dir, tts: tts, sid: sid, speed: speed)
                cont.resume(returning: data)
            }
        }
    }

    /// 分配：优先单音色性别包池轮转，其次多音色包 + 编号列表轮转。分配结果按角色缓存。
    private func assign(characterId: String, gender: Gender,
                        packGenders: [String: String],
                        maleSIDs: [Int32], femaleSIDs: [Int32]) -> (String, Int32)? {
        if let cached = roleAssignments[characterId],
           isInstalled(cached.packId),
           packGenders[cached.packId] != nil {
            return (cached.packId, cached.sid)
        }
        let installedIds = Self.packs.map { $0.id }.filter { isInstalled($0) }
        func pool(_ g: String) -> [String] {
            installedIds.filter { packGenders[$0] == g }
        }
        let femalePacks = pool("female")
        let malePacks = pool("male")
        let multiPacks = pool("multi")

        func rotatePack(_ poolIds: [String], cursorKey: String) -> String {
            let idx = rotationCursor[cursorKey] ?? 0
            rotationCursor[cursorKey] = (idx + 1) % poolIds.count
            return poolIds[idx % poolIds.count]
        }
        func rotateSID(_ list: [Int32], cursorKey: String) -> Int32 {
            guard !list.isEmpty else { return 0 }
            let idx = rotationCursor[cursorKey] ?? 0
            rotationCursor[cursorKey] = (idx + 1) % list.count
            return list[idx % list.count]
        }

        var packId: String? = nil
        var sid: Int32 = 0
        switch gender {
        case .male:
            if !malePacks.isEmpty {
                packId = rotatePack(malePacks, cursorKey: "malePack")
            } else if !multiPacks.isEmpty, !maleSIDs.isEmpty {
                packId = multiPacks[0]
                sid = rotateSID(maleSIDs, cursorKey: "maleSID")
            }
        case .female:
            if !femalePacks.isEmpty {
                packId = rotatePack(femalePacks, cursorKey: "femalePack")
            } else if !multiPacks.isEmpty, !femaleSIDs.isEmpty {
                packId = multiPacks[0]
                sid = rotateSID(femaleSIDs, cursorKey: "femaleSID")
            }
        case .neutral:
            if !femalePacks.isEmpty {
                packId = rotatePack(femalePacks, cursorKey: "femalePack")
            } else if !malePacks.isEmpty {
                packId = rotatePack(malePacks, cursorKey: "malePack")
            } else if !multiPacks.isEmpty {
                packId = multiPacks[0]
                sid = femaleSIDs.first ?? 0
            }
        }
        guard let p = packId else { return nil }
        roleAssignments[characterId] = (p, sid)
        return (p, sid)
    }

    /// 清除角色分配缓存（性别标注/编号列表变化后调用，下次朗读重新分配）
    func resetAssignments() {
        engineQueue.async { [weak self] in self?.roleAssignments.removeAll() }
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
              let tokensRel = firstFile(matching: { $0.hasSuffix("tokens.txt") }) else { return nil }

        var vits = SherpaOnnxOfflineTtsVitsModelConfig()
        vits.model = UnsafePointer(strdup(dir + "/" + modelRel))
        vits.tokens = UnsafePointer(strdup(dir + "/" + tokensRel))
        if let lexiconRel = firstFile(matching: { $0.hasSuffix("lexicon.txt") }) {
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
        // rule fsts 可能位于 data/ 等子目录（icefall aishell3 布局）
        let fsts = (fm.subpaths(atPath: dir) ?? [])
            .filter { ["date.fst", "number.fst"].contains(($0 as NSString).lastPathComponent) }
            .sorted()
            .map { dir + "/" + $0 }
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
