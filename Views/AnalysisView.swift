import SwiftUI
import CoreLogic

/// 展示「整体解析」结果：识别出的角色（含性别、合并别名）与分段预览（说话人/情绪）。
struct AnalysisView: View {
    let analysis: AnalysisResult

    private func roleName(_ id: String?) -> String {
        guard let id else { return "旁白" }
        return analysis.roles.first(where: { $0.id == id })?.canonicalName ?? "未知"
    }

    var body: some View {
        NavigationStack {
            List {
                Section("识别角色（\(analysis.roles.count)）") {
                    if analysis.roles.isEmpty {
                        Text("未识别到明确角色，将按旁白朗读。").foregroundColor(.secondary)
                    }
                    ForEach(analysis.roles) { role in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(role.canonicalName).font(.headline)
                                Spacer()
                                Text(genderLabel(role.gender))
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(genderColor(role.gender).opacity(0.15))
                                    .foregroundColor(genderColor(role.gender))
                                    .cornerRadius(6)
                            }
                            if !role.aliases.isEmpty {
                                Text("别名/代称：" + role.aliases.joined(separator: "、"))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                Section("朗读分段预览") {
                    ForEach(Array(analysis.segments.prefix(300).enumerated()), id: \.element.id) { _, seg in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(roleName(seg.characterId))
                                    .font(.caption.bold())
                                Text(emotionLabel(seg.emotion))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                if seg.characterId == nil {
                                    Text("· 中性声")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Text(seg.text).font(.body)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .navigationTitle("解析结果")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func genderLabel(_ g: Gender) -> String {
        switch g { case .male: return "男"; case .female: return "女"; case .neutral: return "中性" }
    }
    private func genderColor(_ g: Gender) -> Color {
        switch g { case .male: return .blue; case .female: return .pink; case .neutral: return .gray }
    }
    private func emotionLabel(_ e: Emotion) -> String {
        switch e {
        case .joy: return "喜"
        case .anger: return "怒"
        case .sorrow: return "哀"
        case .happiness: return "乐"
        case .neutral: return "平"
        }
    }
}
