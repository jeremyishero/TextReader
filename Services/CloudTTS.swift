import Foundation

/// 云端 TTS 备选通道：OpenAI 兼容 /v1/audio/speech 接口。
/// 用户在设置页填端点与 Key；失败/离线时由 TTSPlayer 自动回退本地合成。
struct CloudTTS {

    var endpoint: String      // 完整 URL，如 https://api.openai.com/v1/audio/speech
    var apiKey: String
    var model: String         // 如 tts-1
    var voice: String         // 如 alloy / echo / nova …

    init(endpoint: String, apiKey: String, model: String = "tts-1", voice: String = "alloy") {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
        self.voice = voice
    }

    var isConfigured: Bool {
        guard let url = URL(string: endpoint), url.scheme == "https" || url.scheme == "http" else { return false }
        return !apiKey.isEmpty
    }

    /// 合成一段文本，返回音频数据（mp3）。失败抛错，由调用方决定回退。
    func synthesize(_ text: String) async throws -> Data {
        guard let url = URL(string: endpoint) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "voice": voice,
            "input": String(text.prefix(4000)),   // 接口一般有长度上限
            "response_format": "mp3"
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
