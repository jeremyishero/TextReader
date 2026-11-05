import Foundation

/// 可选云端解析：把文本发往 OpenAI 兼容的 /v1/chat/completions 接口，
/// 由大模型产出结构化 JSON（角色/别名/性别/分段情绪），解析为 AnalysisResult。
/// 需联网与 API Key；失败由调用方回退本地引擎。纯 Foundation，可在 macOS CI 编译。
public struct CloudAnalyzer {

    public init() {}

    private let systemPrompt = """
    你是一个中文小说解析助手。给定小说文本，请识别所有人物角色，并把同一人物的姓名、称谓、代词、描述词合并为同一个角色（给出稳定 id）。
    判断每个角色的性别（male/female/neutral）。把文本切分为若干朗读分段，每段标注说话角色 id（旁白为 null）与情绪（neutral/joy/anger/sorrow/happiness）。
    只输出 JSON，不要任何解释。
    """

    public static func prompt(for text: String) -> String {
        let truncated = String(text.prefix(20000))
        return """
        请解析以下小说文本：
        \(truncated)

        严格按照如下 JSON 结构输出：
        {
          "roles": [{"id":"角色ID","name":"主名称","aliases":["别名1","别名2"],"gender":"male|female|neutral"}],
          "segments": [{"text":"句子或台词","charId":"角色ID或null","emotion":"neutral|joy|anger|sorrow|happiness"}]
        }
        charId 为 null 表示旁白/叙述。
        """
    }

    /// 调用云端接口解析文本。
    /// - Parameters:
    ///   - text: 待解析文本
    ///   - apiKey: API Key（Bearer）
    ///   - baseURL: OpenAI 兼容的 chat completions 地址
    ///   - model: 模型名
    public func analyze(_ text: String,
                        apiKey: String,
                        baseURL: String = "https://api.openai.com/v1/chat/completions",
                        model: String = "gpt-4o-mini") async throws -> AnalysisResult {
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": Self.prompt(for: text)]
            ],
            "response_format": ["type": "json_object"],
            "temperature": 0.2
        ]
        guard let url = URL(string: baseURL) else {
            throw NSError(domain: "CloudAnalyzer", code: -3, userInfo: [NSLocalizedDescriptionKey: "非法 URL"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60          // 空闲超时：防止云端长时间无响应导致界面一直等待
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw NSError(domain: "CloudAnalyzer", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "无法解析云端返回"])
        }
        return try Self.parseJSON(content)
    }

    /// 将云端返回的 JSON 字符串解析为 AnalysisResult（容错）。
    public static func parseJSON(_ json: String) throws -> AnalysisResult {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "CloudAnalyzer", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "JSON 解析失败"])
        }
        let rolesArr = obj["roles"] as? [[String: Any]] ?? []
        let segsArr = obj["segments"] as? [[String: Any]] ?? []

        var roles: [CharacterRole] = []
        for (i, r) in rolesArr.enumerated() {
            let id = (r["id"] as? String) ?? "role_\(i)"
            let name = (r["name"] as? String) ?? id
            let aliases = (r["aliases"] as? [String]) ?? [name]
            let gender: Gender = (r["gender"] as? String).flatMap { Gender(rawValue: $0) } ?? .neutral
            roles.append(CharacterRole(id: id, canonicalName: name, aliases: aliases, gender: gender, voiceHint: nil))
        }

        var segs: [SpeechSegment] = []
        for (i, s) in segsArr.enumerated() {
            let text = (s["text"] as? String) ?? ""
            let cid = s["charId"] as? String
            let emo: Emotion = (s["emotion"] as? String).flatMap { Emotion(rawValue: $0) } ?? .neutral
            segs.append(SpeechSegment(id: "seg_\(i)", text: text, characterId: cid, emotion: emo, position: i))
        }
        return AnalysisResult(roles: roles, segments: segs)
    }
}
