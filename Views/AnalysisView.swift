import SwiftUI
import AVFoundation
import CoreLogic

/// 展示「整体解析」结果。
/// 左侧固定三个目录按钮（滚动不受影响，可随时展开/折叠，默认折叠）：
/// - 角色：识别出的角色列表，右侧可改名/删除；前 10 个角色可单独选择声音（≤系统可用声音数）；
/// - 黑名单：这些词永远不会被识别为人名；
/// - 白名单：这些词一定是人名/称呼（出现即注册）。
/// 黑/白名单添加时查重：已存在于另一名单则提示「覆盖」或「取消」。
/// 可从其他文档导入人物声音配置（按角色称呼匹配，只影响本文档，不影响导入源）。
struct AnalysisView: View {
    @Binding var analysis: AnalysisResult
    var blacklisted: [String]
    var whitelisted: [String]
    var voiceOverrides: [String: String]
    var otherDocuments: [DocumentItem]
    var onEdited: (() -> Void)? = nil
    var onListsChanged: (([String], [String]) -> Void)? = nil
    var onVoiceChanged: (([String: String]) -> Void)? = nil
    var onImportConfig: ((DocumentItem) -> Void)? = nil

    private enum Panel { case roles, blacklist, whitelist }

    @State private var activePanel: Panel? = nil          // nil = 全部折叠
    @State private var renamingRole: CharacterRole?
    @State private var renameText: String = ""
    @State private var showRenameAlert = false
    @State private var newBlackWord = ""
    @State private var newWhiteWord = ""
    @State private var showImportSheet = false
    // 查重提示
    @State private var dupWord = ""
    @State private var dupFromList: Panel = .blacklist
    @State private var dupTargetList: Panel = .whitelist
    @State private var showDupAlert = false

    /// 可供选择的声音：简体中文普通话优先，最多 10 个（系统有几个就有几个）
    private var voiceOptions: [AVSpeechSynthesisVoice] {
        let all = AVSpeechSynthesisVoice.speechVoices()
        var pool = all.filter { $0.language == "zh-CN" }
        if pool.isEmpty { pool = all.filter { $0.language.hasPrefix("zh-Hans") } }
        if pool.isEmpty { pool = all.filter { $0.language.hasPrefix("zh") } }
        if pool.isEmpty { pool = all }
        return Array(pool.prefix(10))
    }
    /// 前 10 个角色可单独指定声音
    private var assignableRoles: [CharacterRole] {
        Array(analysis.roles.prefix(10))
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .leading) {
                // 主内容：朗读分段预览（滚动时侧栏固定在左侧不受影响）
                List {
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
                .padding(.leading, 58)

                // 左侧固定目录栏
                HStack(spacing: 0) {
                    sidebar
                    if activePanel != nil {
                        panelView
                            .frame(width: 300)
                            .background(.regularMaterial)
                            .transition(.move(edge: .leading))
                    }
                    Spacer(minLength: 0)
                }
            }
            .navigationTitle("解析结果")
            .navigationBarTitleDisplayMode(.inline)
            .animation(.easeInOut(duration: 0.2), value: activePanel)
            .alert("修改角色称呼", isPresented: $showRenameAlert) {
                TextField("新称呼", text: $renameText)
                Button("保存", action: commitRename)
                Button("取消", role: .cancel) {}
            } message: {
                Text("原称呼将保留为该角色的别名之一，朗读时同一角色仍使用同一声音。")
            }
            .alert("该词已存在", isPresented: $showDupAlert) {
                Button("覆盖", action: moveDupWord)
                Button("取消", role: .cancel) {}
            } message: {
                Text(dupMessage)
            }
            .sheet(isPresented: $showImportSheet) {
                importSheet
            }
        }
    }

    // MARK: 侧栏

    private var sidebar: some View {
        VStack(spacing: 16) {
            sidebarButton(icon: "person.2.fill", label: "角色", panel: .roles)
            sidebarButton(icon: "hand.raised.fill", label: "黑名单", panel: .blacklist)
            sidebarButton(icon: "checkmark.seal.fill", label: "白名单", panel: .whitelist)
            Spacer()
        }
        .frame(width: 56)
        .padding(.top, 24)
        .background(Color(.systemGray6))
    }

    private func sidebarButton(icon: String, label: String, panel: Panel) -> some View {
        Button {
            // 再点一次当前目录 → 折叠
            activePanel = (activePanel == panel) ? nil : panel
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                Text(label)
                    .font(.system(size: 9))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(activePanel == panel ? Color.accentColor.opacity(0.18) : Color.clear)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .foregroundColor(activePanel == panel ? .accentColor : .primary)
    }

    // MARK: 面板

    @ViewBuilder
    private var panelView: some View {
        ScrollView {
            switch activePanel {
            case .roles: rolesPanel
            case .blacklist: blacklistPanel
            case .whitelist: whitelistPanel
            case nil: EmptyView()
            }
        }
    }

    private var rolesPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            panelHeader("角色（\(analysis.roles.count)）")
            HStack {
                Button {
                    showImportSheet = true
                } label: {
                    Label("导入其他文档配置", systemImage: "square.and.arrow.down")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .disabled(otherDocuments.isEmpty)
                if otherDocuments.isEmpty {
                    Text("暂无其他已配置文档")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            if analysis.roles.isEmpty {
                Text("未识别到明确角色，将按旁白朗读。").foregroundColor(.secondary)
            }
            ForEach(Array(analysis.roles.enumerated()), id: \.element.id) { idx, role in
                roleRow(role, index: idx)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private func roleRow(_ role: CharacterRole, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text("\(index + 1). \(role.canonicalName)")
                    .font(.headline)
                Spacer()
                Text(genderLabel(role.gender))
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(genderColor(role.gender).opacity(0.15))
                    .foregroundColor(genderColor(role.gender))
                    .cornerRadius(5)
                Button {
                    renamingRole = role
                    renameText = role.canonicalName
                    showRenameAlert = true
                } label: {
                    Image(systemName: "pencil").font(.caption)
                }
                .buttonStyle(.borderless)
                Button {
                    deleteRole(role)
                } label: {
                    Image(systemName: "trash").font(.caption).foregroundColor(.red)
                }
                .buttonStyle(.borderless)
            }
            if !role.aliases.isEmpty {
                Text("别名：" + role.aliases.joined(separator: "、"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            // 前 10 个角色可单独选择声音（系统声音不足 10 个则有几个设几个）
            if index < 10, !voiceOptions.isEmpty {
                Picker("声音", selection: voiceBinding(for: role)) {
                    Text("自动分配").tag(String?.none)
                    ForEach(voiceOptions, id: \.identifier) { v in
                        Text("\(v.name)（普通话）").tag(String?.some(v.identifier))
                    }
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }

    private var blacklistPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            panelHeader("黑名单（\(blacklisted.count)）")
            Text("名单中的词永远不会被识别为人名。重新「整体解析」后生效。")
                .font(.caption2).foregroundColor(.secondary)
            wordEditor(text: $newBlackWord, placeholder: "输入要屏蔽的词") { addWord(newBlackWord, to: .blacklist) }
            ForEach(blacklisted, id: \.self) { w in
                wordRow(w) { removeWord(w, from: .blacklist) }
            }
        }
        .padding(12)
    }

    private var whitelistPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            panelHeader("白名单（\(whitelisted.count)）")
            Text("名单中的词一定是人名或称呼，出现即识别为角色（即使只出现一次）。重新「整体解析」后生效。")
                .font(.caption2).foregroundColor(.secondary)
            wordEditor(text: $newWhiteWord, placeholder: "输入一定是人名的词") { addWord(newWhiteWord, to: .whitelist) }
            ForEach(whitelisted, id: \.self) { w in
                wordRow(w) { removeWord(w, from: .whitelist) }
            }
        }
        .padding(12)
    }

    private func panelHeader(_ title: String) -> some View {
        Text(title).font(.headline)
    }

    private func wordEditor(text: Binding<String>, placeholder: String, onSubmit: @escaping () -> Void) -> some View {
        HStack {
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            Button("添加", action: onSubmit)
                .buttonStyle(.borderedProminent)
        }
    }

    private func wordRow(_ word: String, onDelete: @escaping () -> Void) -> some View {
        HStack {
            Text(word)
            Spacer()
            Button {
                onDelete()
            } label: {
                Image(systemName: "trash").font(.caption).foregroundColor(.red)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    // MARK: 名单操作与查重

    private var dupMessage: String {
        let from = dupFromList == .blacklist ? "黑名单" : "白名单"
        let to = dupTargetList == .blacklist ? "黑名单" : "白名单"
        return "「\(dupWord)」已存在于\(from)中。选择「覆盖」将从\(from)移除并加入\(to)；选择「取消」不做修改。"
    }

    private func addWord(_ raw: String, to target: Panel) {
        let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        if target == .blacklist {
            newBlackWord = ""
            if blacklisted.contains(word) { return }               // 同名单内已存在：忽略
            if whitelisted.contains(word) {                        // 跨名单重复 → 查重提示
                dupWord = word; dupFromList = .whitelist; dupTargetList = .blacklist
                showDupAlert = true
                return
            }
            onListsChanged?(blacklisted + [word], whitelisted)
        } else {
            newWhiteWord = ""
            if whitelisted.contains(word) { return }
            if blacklisted.contains(word) {
                dupWord = word; dupFromList = .blacklist; dupTargetList = .whitelist
                showDupAlert = true
                return
            }
            onListsChanged?(blacklisted, whitelisted + [word])
        }
    }

    /// 查重弹窗的「覆盖」：从原名单移除，加入目标名单
    private func moveDupWord() {
        if dupTargetList == .blacklist {
            onListsChanged?(blacklisted + [dupWord], whitelisted.filter { $0 != dupWord })
        } else {
            onListsChanged?(blacklisted.filter { $0 != dupWord }, whitelisted + [dupWord])
        }
    }

    private func removeWord(_ word: String, from target: Panel) {
        if target == .blacklist {
            onListsChanged?(blacklisted.filter { $0 != word }, whitelisted)
        } else {
            onListsChanged?(blacklisted, whitelisted.filter { $0 != word })
        }
    }

    // MARK: 角色操作

    private func voiceBinding(for role: CharacterRole) -> Binding<String?> {
        Binding(
            get: { voiceOverrides[role.canonicalName] },
            set: { newValue in
                var updated = voiceOverrides
                updated[role.canonicalName] = newValue
                onVoiceChanged?(updated)
            }
        )
    }

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
        for i in analysis.segments.indices where analysis.segments[i].characterId == role.id {
            analysis.segments[i].characterId = nil
        }
        onEdited?()
    }

    // MARK: 导入其他文档配置

    private var importSheet: some View {
        NavigationStack {
            List {
                ForEach(otherDocuments) { doc in
                    Button {
                        showImportSheet = false
                        onImportConfig?(doc)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(doc.name)
                            Text("导入其人物声音配置（按称呼匹配，仅对本文档生效）")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("选择文档")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { showImportSheet = false }
                }
            }
        }
    }

    // MARK: 展示辅助

    private func roleName(_ id: String?) -> String {
        guard let id else { return "旁白" }
        return analysis.roles.first(where: { $0.id == id })?.canonicalName ?? "未知"
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
