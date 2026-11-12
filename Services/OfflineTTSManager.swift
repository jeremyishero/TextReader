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

/// 角色声音选择的统一编码。
/// voiceOverrides 历史值是「系统声 identifier」（无前缀），新增的离线包用 "offline:<packId>:<sid>"。
/// 旧配置无需迁移：无前缀即按系统声解析，天然兼容。
enum VoiceChoice {
    static let offlinePrefix = "offline:"

    static func encode(packId: String, sid: Int32) -> String {
        "\(offlinePrefix)\(packId):\(sid)"
    }

    /// 解析离线选择；返回 nil 表示「系统声 identifier」或未识别的旧值。
    static func decode(_ raw: String) -> (packId: String, sid: Int32)? {
        guard raw.hasPrefix(offlinePrefix) else { return nil }
        let body = String(raw.dropFirst(offlinePrefix.count))
        // 从末尾切分，兼容 packId 内含冒号的极端情况
        guard let colon = body.lastIndex(of: ":") else { return nil }
        let packId = String(body[..<colon])
        let sid = Int32(String(body[body.index(after: colon)...])) ?? 0
        guard !packId.isEmpty else { return nil }
        return (packId, sid)
    }

    static func isOffline(_ raw: String) -> Bool { raw.hasPrefix(offlinePrefix) }
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

    /// 已安装包列表缓存。磁盘扫描较慢，且 AnalysisView 每个角色行渲染都会读一次，
    /// 不缓存会造成打开角色面板卡顿。安装在下载完成/删除/导入后变化时显式失效。
    private var installedPacksCache: [VoicePackInfo]?
    private let packsCacheLock = NSLock()

    /// 安装状态变化后调用：清空缓存，下次读取重新扫描磁盘。
    private func invalidateInstalledPacks() {
        packsCacheLock.lock()
        defer { packsCacheLock.unlock() }
        installedPacksCache = nil
    }

    /// 磁盘上所有「已安装」的语音包：静态 packs 表内已装的 + 从 zip 导入的自定义包。
    /// 导入包的 id 是压缩包内根文件夹名（任意字符串），不在静态表里，
    /// 因此必须扫描 VoicePacks 目录本身，否则导入包永远选不到、也进不了自动分配池。
    func installedPacks() -> [VoicePackInfo] {
        packsCacheLock.lock()
        defer { packsCacheLock.unlock() }
        if let cached = installedPacksCache {
            return cached
        }
        var out: [VoicePackInfo] = []
        var seen = Set<String>()
        for p in Self.packs where isInstalled(p.id) {
            out.append(p)
            seen.insert(p.id)
        }
        let dirs = (try? fm.contentsOfDirectory(atPath: packsRoot.path)) ?? []
        for dir in dirs where !seen.contains(dir) {
            // 跳过下载过程可能残留的非目录项；isInstalled 已隐含目录校验
            guard isInstalled(dir) else { continue }
            out.append(.init(id: dir, repo: "",
                             displayName: dir + " · 导入包",
                             gender: "导入", sizeMB: 0))
            seen.insert(dir)
        }
        installedPacksCache = out
        return out
    }

    /// 未标注性别的包用于自动分配时的兜底（导入包默认按中性参与轮转，保证「导入即可用」）。
    static func defaultGender(for packId: String) -> String {
        if let p = packs.first(where: { $0.id == packId }) {
            if p.gender.contains("女") { return "female" }
            if p.gender.contains("男") { return "male" }
            if p.gender.contains("多音色") { return "multi" }
        }
        return "neutral"
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
                self.invalidateInstalledPacks()
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
        invalidateInstalledPacks()
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
        invalidateInstalledPacks()
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

    /// 旁白专用合成：直接用指定离线包（绕过性别池分配），供「旁白改用导入的离线声音」使用。
    /// 多音色包按 sid 选说话人；单音色包忽略 sid。
    func synthesizeWithPack(text: String, packId: String, sid: Int32, speed: Float) async -> Data? {
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

    /// 分配：优先单音色性别包池轮转，其次多音色包 + 编号列表轮转。分配结果按角色缓存。
    private func assign(characterId: String, gender: Gender,
                        packGenders: [String: String],
                        maleSIDs: [Int32], femaleSIDs: [Int32]) -> (String, Int32)? {
        if let cached = roleAssignments[characterId],
           isInstalled(cached.packId) {
            return (cached.packId, cached.sid)
        }
        // 用磁盘扫描结果（含 zip 导入的自定义包），而不是只遍历静态 packs 表
        let installedIds = installedPacks().map(\.id)
        func genderOf(_ id: String) -> String {
            // 用户显式标注优先（"" 表示「不参与」）；未标注的导入包按默认性别参与轮转
            if let g = packGenders[id] { return g }
            return Self.defaultGender(for: id)
        }
        func pool(_ g: String) -> [String] {
            installedIds.filter { genderOf($0) == g }
        }
        let femalePacks = pool("female")
        let malePacks = pool("male")
        let multiPacks = pool("multi")
        let neutralPacks = pool("neutral")

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
            // 中性 = 性别未知，绝不应一律配女声（否则「解析角色多为中性」时听起来全是女声）。
            // 改为在「男声池 + 女声池 + 中性声池」之间交替轮转，未知性别角色的声音性别大致均衡；
            // 完全没有对应性别包时，再退化到多音色包（按女声编号优先）。
            var mixed: [String] = []
            let maxN = max(malePacks.count, femalePacks.count, neutralPacks.count)
            for i in 0..<maxN {
                if i < malePacks.count { mixed.append(malePacks[i]) }
                if i < femalePacks.count { mixed.append(femalePacks[i]) }
                if i < neutralPacks.count { mixed.append(neutralPacks[i]) }
            }
            if !mixed.isEmpty {
                packId = rotatePack(mixed, cursorKey: "neutralMixed")
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
        guard ok else { return nil }
        return Self.normalizeWAV(buffer)
    }

    /// 将 VITS 生成的 WAV 做响度归一化（RMS 对齐到目标值，且峰值不超过上限），
    /// 解决不同句子响度不一致导致的「声音时大时小」问题（尤其单音色 / 长者类离线包）。
    /// 仅处理 16-bit PCM 的 WAV；其它格式原样返回。
    private static func normalizeWAV(_ data: Data) -> Data {
        guard data.count > 44,
              data[0] == 0x52, data[1] == 0x49, data[2] == 0x46, data[3] == 0x46,   // RIFF
              data[8] == 0x57, data[9] == 0x41, data[10] == 0x56, data[11] == 0x45  // WAVE
        else { return data }
        let audioFormat = Int(data[20]) | (Int(data[21]) << 8)
        let bits = Int(data[34]) | (Int(data[35]) << 8)
        guard audioFormat == 1, bits == 16 else { return data }

        // 找到 data chunk 的偏移与长度（兼容 fmt 之后可能存在的扩展字段 / 额外块）
        var offset = 12
        var dataOffset = -1, dataSize = 0
        while offset + 8 <= data.count {
            let ck = String(data: data[offset..<offset + 4], encoding: .ascii) ?? ""
            let sz = Int(data[offset + 4]) | (Int(data[offset + 5]) << 8)
                      | (Int(data[offset + 6]) << 16) | (Int(data[offset + 7]) << 24)
            if ck == "data" { dataOffset = offset + 8; dataSize = sz; break }
            offset += 8 + sz + (sz & 1)   // 块按偶数字节对齐
        }
        guard dataOffset > 0, dataSize > 0, dataOffset + dataSize <= data.count else { return data }
        let sampleCount = dataSize / 2
        guard sampleCount > 0 else { return data }

        let slice = data.subdata(in: dataOffset..<dataOffset + dataSize)
        let samples = slice.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Int16.self))
        }

        var sumSq = 0.0, peak: Double = 0
        for s in samples {
            let v = Double(s)
            sumSq += v * v
            let a = abs(v)
            if a > peak { peak = a }
        }
        let rms = sqrt(sumSq / Double(sampleCount))
        let fullScale = Double(Int16.max)
        guard rms > 0, peak > 0 else { return data }

        // 目标 RMS ≈ -16 dBFS（朗读舒适响度）；若缩放后峰值超过 0.98 满幅则按峰值限幅，避免削波
        let targetRMS: Double = 0.16
        let maxPeak: Double = 0.98
        var scale = targetRMS / rms
        if peak * scale > maxPeak * fullScale {
            scale = (maxPeak * fullScale) / peak
        }
        guard scale.isFinite, scale > 0 else { return data }

        let out = samples.map { s -> Int16 in
            let v = Double(s) * scale
            return Int16(max(Double(Int16.min), min(Double(Int16.max), v)))
        }
        var result = data
        let newData = out.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: $0.count) }
        result.replaceSubrange(dataOffset..<dataOffset + dataSize, with: newData)
        return result
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
