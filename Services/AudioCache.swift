import Foundation
import CryptoKit

/// 合成音频磁盘缓存：合成一次、落盘，之后（后台、切章、重启 App）直接读缓存播放，
/// 彻底避免「每次都重新合成 10-20 秒」。真机日志证实重复合成是后台被强杀与音色失效的根因。
///
/// 缓存键 = 文档 id + 段文字 + 音色签名 的 SHA256（取前 16 字节转十六进制）。
/// 用「文字」而非段索引：切章/重新解析后索引会变，但同一段文字的音色应一致。
/// 用「音色签名」：用户改了声音配置后旧缓存自动失效，不会串音。
final class AudioCache {
    static let shared = AudioCache()

    private let fm = FileManager.default
    private let root: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return d.appendingPathComponent("SpeechAudioCache", isDirectory: true)
    }()
    /// 缓存上限（字节）：默认 150MB。超出后按「最久未访问」淘汰。
    private let maxBytes: Int64 = 150 * 1024 * 1024

    private init() {
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// 音色签名：任何一个影响声音的设置变化，都让缓存 key 改变（旧缓存自然作废）。
    /// 由 TTSPlayer 在起播时算好传入。
    static func voiceSignature(documentId: String?,
                               mode: String,
                               manualPacks: [String: (packId: String, sid: Int32)],
                               manualSystemIds: Set<String>,
                               roleSlots: [String: (packId: String, sid: Int32)],
                               defaultVoice: String?,
                               rate: Float) -> String {
        var parts: [String] = [documentId ?? "", mode]
        // 按 key 排序保证稳定
        for key in manualPacks.keys.sorted() {
            let v = manualPacks[key]!
            parts.append("\(key)=\(v.packId):\(v.sid)")
        }
        // 主角/配角声音槽：任一槽变化都让旧缓存失效，避免串音
        for key in roleSlots.keys.sorted() {
            let v = roleSlots[key]!
            parts.append("role=\(key):\(v.packId):\(v.sid)")
        }
        parts.append("sys=\(manualSystemIds.sorted().joined(separator: ","))")
        parts.append("def=\(defaultVoice ?? "")")
        parts.append("rate=\(String(format: "%.2f", rate))")
        return parts.joined(separator: "|")
    }

    private func key(documentId: String?, text: String, voiceSig: String) -> String {
        let raw = "\(voiceSig)|\(text)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func fileURL(_ key: String) -> URL {
        root.appendingPathComponent(key + ".wav")
    }

    /// 读缓存；命中时顺带更新访问时间（用于 LRU 淘汰）。
    func data(documentId: String?, text: String, voiceSig: String) -> Data? {
        let k = key(documentId: documentId, text: text, voiceSig: voiceSig)
        let url = fileURL(k)
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return data
    }

    /// 写缓存（原子写，避免半截文件）。
    func store(documentId: String?, text: String, voiceSig: String, data: Data) {
        let k = key(documentId: documentId, text: text, voiceSig: voiceSig)
        let url = fileURL(k)
        try? data.write(to: url, options: .atomic)
        pruneIfNeeded()
    }

    /// 超上限时按修改时间从旧到新删除，直到降到上限的 80%。
    private func pruneIfNeeded() {
        guard let files = try? fm.contentsOfDirectory(at: root,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]),
              !files.isEmpty else { return }
        let entries = files.compactMap { url -> (URL, Int64, Date)? in
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            else { return nil }
            return (url, Int64(size), date)
        }
        let total = entries.reduce(Int64(0)) { $0 + $1.1 }
        guard total > maxBytes else { return }
        let target = Int64(Double(maxBytes) * 0.8)
        var current = total
        for e in entries.sorted(by: { $0.2 < $1.2 }) {
            guard current > target else { break }
            if (try? fm.removeItem(at: e.0)) != nil { current -= e.1 }
        }
        AppLogger.log("音频缓存清理: \(total / 1024 / 1024)MB → \(current / 1024 / 1024)MB")
    }

    /// 清空全部缓存（设置页可调用）。
    func clearAll() {
        guard let files = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for f in files { try? fm.removeItem(at: f) }
        AppLogger.log("音频缓存已清空")
    }

    /// 当前缓存占用（MB，供设置页显示）。
    var sizeMB: Int {
        guard let files = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        let bytes = files.reduce(Int64(0)) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return Int(bytes / 1024 / 1024)
    }
}
