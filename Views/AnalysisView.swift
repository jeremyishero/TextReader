import SwiftUI
import CoreLogic

/// 展示「整体解析」结果：识别出的角色（含性别、合并别名）与分段预览（说话人/情绪）。
/// 每个角色右侧有改名（铅笔）与删除（垃圾桶）按钮，用于人工修正误识别；
/// 修改通过 Binding 回传给 ReadingView 并重新持久化。
struct AnalysisView: View {
    @Binding var analysis: AnalysisResult
    var onEdited: (() -> Void)? = nil

    @State private var renamingRole: CharacterRole?
    @State private var renameText: String = ""
    @State private var showRenameAlert = false

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
                        roleRow(role)
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
            .alert(
                "修改角色称呼",
                isPresented: $showRenameAlert
            ) {
                TextField("新称呼", text: $renameText)
                Button("保存", action: commitRename)
                Button("取消", role: .cancel) {}
            } message: {
                Text("原称呼将保留为该角色的别名之一，朗读时同一角色仍使用同一声音。")
            }
        }
    }

    // MARK: 角色行（名称 + 性别 + 改名/删除按钮）

    @ViewBuilder
    private func roleRow(_ role: CharacterRole) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(role.canonicalName).font(.headline)
                Spacer()
                Text(genderLabel(role.gender))
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(genderColor(role.gender).opacity(0.15))
                    .foregroundColor(genderColor(role.gender))
                    .cornerRadius(6)
                // 改名按钮
                Button {
                    renamingRole = role
                    renameText = role.canonicalName
                    showRenameAlert = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                // 删除按钮
                Button {
                    deleteRole(role)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundColor(.red)
                }
                .buttonStyle(.borderless)
            }
            if !role.aliases.isEmpty {
                Text("别名/代称：" + role.aliases.joined(separator: "、"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: 编辑操作

    private func commitRename() {
        let newName = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target = renamingRole, !newName.isEmpty,
              let idx = analysis.roles.firstIndex(where: { $0.id == target.id }) else { return }
        let old = analysis.roles[idx].canonicalName
        analysis.roles[idx].canonicalName = newName
        if old != newName, !analysis.roles[idx].aliases.contains(old) {
            analysis.roles[idx].aliases.append(old)
        }
        onEdited?()
    }

    private func deleteRole(_ role: CharacterRole) {
        analysis.roles.removeAll { $0.id == role.id }
        // 该角色的所有台词降级为旁白（中性声）
        for i in analysis.segments.indices where analysis.segments[i].characterId == role.id {
            analysis.segments[i].characterId = nil
        }
        onEdited?()
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
