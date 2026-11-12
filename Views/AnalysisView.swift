import SwiftUI
import UIKit
import AVFoundation
import CoreLogic
import UniformTypeIdentifiers

/// 展示「整体解析」结果。
/// 左侧固定四个目录按钮（滚动不受影响；默认展开「角色」，点一下收起/展开）：
/// - 角色：角色列表（分页展示，每页 10 个，避免角色过多时卡顿），右侧可改名/删除（删除需确认）；
///         前 10 个角色可单独选择声音（≤系统可用声音数）；可导入其他文档的人物声音配置；
/// - 黑名单：这些词永远不会被识别为人名；
/// - 白名单：这些词一定是人名/称呼（出现即注册）；
/// - 规则：自定义朗读规则（≤20 条），朗读时把「匹配文本」替换为「替换文本」。
/// 黑/白名单添加时查重：已存在于另一名单则提示「覆盖」或「取消」。
struct AnalysisView: View {
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var offlineMgr = OfflineTTSManager.shared

    @Binding var analysis: AnalysisResult
    var blacklisted: [String]
    var whitelisted: [String]
    var voiceOverrides: [String: String]
    var otherDocuments: [DocumentItem]
    var rules: [CustomRule]
    var onEdited: (() -> Void)? = nil
    var onListsChanged: (([String], [String]) -> Void)? = nil
    var onVoiceChanged: (([String: String]) -> Void)? = nil
    var onImportConfig: ((DocumentItem) -> Void)? = nil
    var onRulesChanged: (([CustomRule]) -> Void)? = nil

    private enum Panel { case roles, blacklist, whitelist, rules }

    @State private var activePanel: Panel? = .roles      // 默认展开「角色」
    @State private var visibleRoleCount = 10              // 角色分页：每页 10 个
    // 修改角色（称呼 + 性别）：用 sheet 承载 TextField + Picker
    @State private var showEditSheet = false
    @State private var editingRole: CharacterRole? = nil
    @State private var editNameText: String = ""
    @State private var editGender: Gender = .neutral
    // 拉黑角色确认
    @State private var showBlacklistConfirm = false
    @State private var blacklistTarget: CharacterRole? = nil
    @State private var newBlackWord = ""
    @State private var newWhiteWord = ""
    @State private var showImportSheet = false
    // 删除确认
    @State private var showDeleteConfirm = false
    @State private var deleteTarget: DeleteTarget? = nil
    // 查重提示
    @State private var dupWord = ""
    @State private var dupFromList: Panel = .blacklist
    @State private var dupTargetList: Panel = .whitelist
    @State private var showDupAlert = false
    // 规则编辑
    @State private var showRuleAlert = false
    @State private var ruleFindDraft = ""
    @State private var ruleReplaceDraft = ""
    @State private var editingRuleFind: String? = nil     // nil = 新增；否则为编辑既有规则
    // 从文本导入角色
    @State private var showTextImportSheet = false
    @State private var importText = ""
    @State private var importSummary: String? = nil
    // 从表格(.xlsx)导入角色
    @State private var showXlsxImporter = false
    // 导出当前角色列表为 .xlsx 并分享
    @State private var showShareSheet = false
    @State private var exportURL: URL? = nil
    @State private var exportError: String? = nil
    // 导入方式二选一：替换所有已存在角色 / 新增到现有角色
    @State private var showImportModeDialog = false
    @State private var pendingImport: [(name: String, gender: Gender, aliases: [String])]? = nil
    // 角色多选删除（长按进入）
    @State private var multiSelectMode = false
    @State private var selectedRoleIds: Set<String> = []
    @State private var showMultiDeleteConfirm = false

    private enum DeleteTarget {
        case role(CharacterRole)
        case word(String, Panel)
        case rule(CustomRule)
    }

    /// 可供选择的声音：简体中文普通话优先，最多 10 个（系统有几个就有几个）。
    /// 缓存为静态：AVSpeechSynthesisVoice.speechVoices() 是较慢的系统调用，
    /// 之前每个角色行渲染都会调一次（10 行 = 10 次），是「打开角色面板卡顿」的主要元凶。
    private static let cachedVoiceOptions: [AVSpeechSynthesisVoice] = {
        let all = AVSpeechSynthesisVoice.speechVoices()
        var pool = all.filter { $0.language == "zh-CN" }
        if pool.isEmpty { pool = all.filter { $0.language.hasPrefix("zh-Hans") } }
        if pool.isEmpty { pool = all.filter { $0.language.hasPrefix("zh") } }
        if pool.isEmpty { pool = all }
        return Array(pool.prefix(10))
    }()
    private var voiceOptions: [AVSpeechSynthesisVoice] { Self.cachedVoiceOptions }

    /// 统一的「可选声音」：值为存入 voiceOverrides 的字符串（系统声 identifier 或 offline:<packId>:<sid>）。
    private struct VoiceOption: Identifiable {
        let id: String
        let name: String
    }

    /// 已下载 / 已导入的离线包选项。installedPacks() 是磁盘扫描，
    /// 故缓存到 @State，仅在视图出现或安装状态版本变化时刷新，避免角色行反复求值全量扫盘。
    @State private var offlineVoiceOptions: [VoiceOption] = []

    private func refreshOfflineVoiceOptions() {
        var out: [VoiceOption] = []
        for pack in offlineMgr.installedPacks() {
            let annotated = settings.offlinePackGenders[pack.id]
            let isMulti = (annotated == "multi")
                || (annotated == nil && OfflineTTSManager.defaultGender(for: pack.id) == "multi")
            let sidList: [Int32] = {
                guard isMulti else { return [0] }
                let raw = settings.offlineTTSMaleSIDs + "," + settings.offlineTTSFemaleSIDs
                var seen = Set<Int32>()
                let ids = raw.split(separator: ",")
                    .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
                    .filter { seen.insert($0).inserted }
                return ids.isEmpty ? [0] : ids
            }()
            for sid in sidList {
                let suffix = isMulti ? " · #\(sid)" : ""
                out.append(.init(id: VoiceChoice.encode(packId: pack.id, sid: sid),
                                 name: "离线｜" + pack.displayName + suffix))
            }
        }
        offlineVoiceOptions = out
    }

    /// 前 10 个角色可单独指定声音
    private var assignableRoles: [CharacterRole] {
        Array(analysis.roles.prefix(10))
    }
    /// 当前分页可见的角色
    private var visibleRoles: [CharacterRole] {
        Array(analysis.roles.prefix(visibleRoleCount))
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .leading) {
                // 主内容：提示（目录都收起时看到）
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "sidebar.left")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("使用左侧目录查看角色、名单与规则")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)

                // 左侧固定目录栏 + 展开的目录面板（无动画，点击立现）
                HStack(spacing: 0) {
                    sidebar
                    if activePanel != nil {
                        panelView
                            .frame(width: 300)
                            .background(.regularMaterial)
                    }
                    Spacer(minLength: 0)
                }
            }
            .navigationTitle("解析结果")
            .navigationBarTitleDisplayMode(.inline)
            .task { refreshOfflineVoiceOptions() }
            .onChange(of: offlineMgr.revision) { _ in refreshOfflineVoiceOptions() }
            .sheet(isPresented: $showEditSheet) {
                editRoleSheet
            }
            .confirmationDialog(
                "拉黑角色",
                isPresented: $showBlacklistConfirm,
                titleVisibility: .visible
            ) {
                Button("拉黑", role: .destructive, action: executeBlacklist)
                Button("取消", role: .cancel) {}
            } message: {
                Text(blacklistConfirmMessage)
            }
            .alert("该词已存在", isPresented: $showDupAlert) {
                Button("覆盖", action: moveDupWord)
                Button("取消", role: .cancel) {}
            } message: {
                Text(dupMessage)
            }
            .alert(editingRuleFind == nil ? "添加新规则" : "修改规则", isPresented: $showRuleAlert) {
                TextField("匹配文本（朗读中出现）", text: $ruleFindDraft)
                TextField("替换文本（改为朗读）", text: $ruleReplaceDraft)
                Button("保存", action: commitRule)
                Button("取消", role: .cancel) {}
            } message: {
                Text("朗读时把「匹配文本」替换为「替换文本」。例：匹配「……」替换为「……无语」，人物说话出现省略号时会多读一句「无语」。")
            }
            .confirmationDialog("确认删除", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("删除", role: .destructive, action: executeDelete)
                Button("取消", role: .cancel) {}
            } message: {
                Text(deleteConfirmMessage)
            }
            .sheet(isPresented: $showImportSheet) {
                importSheet
            }
            .sheet(isPresented: $showTextImportSheet) {
                textImportSheet
            }
            .sheet(isPresented: $showShareSheet) {
                if let exportURL {
                    ActivityView(url: exportURL)
                }
            }
            .fileImporter(
                isPresented: $showXlsxImporter,
                allowedContentTypes: [xlsxType],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    importRolesFromXlsx(url)
                case .failure(let error):
                    // 用户取消选择：静默返回，不算异常
                    guard (error as? CocoaError)?.code != .userCancelled else { return }
                    importSummary = "打开文件选择器失败：\(error.localizedDescription)"
                }
            }
            .confirmationDialog(
                "选择导入方式",
                isPresented: $showImportModeDialog,
                titleVisibility: .visible
            ) {
                Button("替换所有已存在角色", role: .destructive) { applyImport(replaceExisting: true) }
                Button("新增到现有角色") { applyImport(replaceExisting: false) }
                Button("取消", role: .cancel) { pendingImport = nil }
            } message: {
                Text("「替换」将删除当前所有已存在角色，改用导入的角色；「新增」将导入角色合并进现有角色（按称呼匹配）。")
            }
            .confirmationDialog(
                multiDeleteMessage,
                isPresented: $showMultiDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive, action: executeMultiDelete)
                Button("取消", role: .cancel) {}
            }
            .alert("导入完成", isPresented: Binding(
                get: { importSummary != nil },
                set: { if !$0 { importSummary = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(importSummary ?? "")
            }
            .alert("导出失败", isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(exportError ?? "")
            }
        }
    }

    // MARK: 导出角色表(.xlsx)

    /// 把当前角色列表写成与「从表格导入」兼容的 .xlsx，再调系统分享面板
    ///（隔空投送 / 存储到文件 / 微信等）。台词数从当前解析结果实时统计。
    private func exportRolesToXlsx() {
        var counts: [String: Int] = [:]
        for seg in analysis.segments {
            if let id = seg.characterId { counts[id, default: 0] += 1 }
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmm"
        let name = "角色表-\(fmt.string(from: Date())).xlsx"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try XlsxRoleExporter().export(roles: analysis.roles, quoteCounts: counts, to: url)
            exportURL = url
            showShareSheet = true
        } catch {
            exportError = error.localizedDescription
        }
    }

    // MARK: 侧栏

    private var sidebar: some View {
        VStack(spacing: 14) {
            sidebarButton(icon: "person.2.fill", label: "角色", panel: .roles)
            sidebarButton(icon: "hand.raised.fill", label: "黑名单", panel: .blacklist)
            sidebarButton(icon: "checkmark.seal.fill", label: "白名单", panel: .whitelist)
            sidebarButton(icon: "wand.and.stars", label: "规则", panel: .rules)
            Spacer()
        }
        .frame(width: 56)
        .padding(.top, 24)
        .background(Color(.systemGray6))
    }

    private func sidebarButton(icon: String, label: String, panel: Panel) -> some View {
        Button {
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
        // LazyVStack：只渲染可见行，目录内容再多也秒开
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                switch activePanel {
                case .roles: rolesPanel
                case .blacklist: blacklistPanel
                case .whitelist: whitelistPanel
                case .rules: rulesPanel
                case nil: EmptyView()
                }
            }
            .padding(.vertical, 6)
        }
    }

    // MARK: 角色面板（分页防卡）

    private var rolesPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 标题行：多选模式下右上角变为「取消 / 删除(N)」
            HStack {
                panelHeader("角色（\(analysis.roles.count)）")
                Spacer()
                if multiSelectMode {
                    Button("取消") {
                        multiSelectMode = false
                        selectedRoleIds = []
                    }
                    .font(.caption)
                    Button {
                        showMultiDeleteConfirm = true
                    } label: {
                        Label("删除(\(selectedRoleIds.count))", systemImage: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .disabled(selectedRoleIds.isEmpty)
                }
            }
            if !multiSelectMode {
                HStack {
                    Button {
                        showImportSheet = true
                    } label: {
                        Label("导入其他文档配置", systemImage: "square.and.arrow.down")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .disabled(otherDocuments.isEmpty)
                }
                HStack {
                    Button {
                        importText = ""
                        showTextImportSheet = true
                    } label: {
                        Label("从文本导入角色", systemImage: "doc.text")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    Button {
                        showXlsxImporter = true
                    } label: {
                        Label("从表格导入(.xlsx)", systemImage: "tablecells")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                }
                HStack {
                    Button {
                        exportRolesToXlsx()
                    } label: {
                        Label("导出角色表(.xlsx)", systemImage: "square.and.arrow.up")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .disabled(analysis.roles.isEmpty)
                }
                Text("导出的表格可用「从表格导入」再导回，方便在电脑上批量改名/改性别。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("长按任一角色可进入多选批量删除")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else {
                Text("已选 \(selectedRoleIds.count) 个角色，点右上角「删除」批量删除")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            if analysis.roles.isEmpty {
                Text("未识别到明确角色，将按旁白朗读。").foregroundColor(.secondary)
            }
            ForEach(Array(visibleRoles.enumerated()), id: \.element.id) { idx, role in
                roleRow(role, index: idx)
            }
            // 分页加载：只渲染已展开的部分，角色再多也不卡
            if visibleRoleCount < analysis.roles.count {
                Button {
                    visibleRoleCount += 10
                } label: {
                    Label("显示更多（还有 \(analysis.roles.count - visibleRoleCount) 个）", systemImage: "chevron.down")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private func roleRow(_ role: CharacterRole, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                // 多选模式：左侧复选框
                if multiSelectMode {
                    Image(systemName: selectedRoleIds.contains(role.id) ? "checkmark.circle.fill" : "circle")
                        .font(.body)
                        .foregroundColor(selectedRoleIds.contains(role.id) ? .accentColor : .secondary)
                }
                Text("\(index + 1). \(role.canonicalName)")
                    .font(.headline)
                Spacer()
                if !multiSelectMode {
                    Text(genderLabel(role.gender))
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(genderColor(role.gender).opacity(0.15))
                        .foregroundColor(genderColor(role.gender))
                        .cornerRadius(5)
                    // 拉黑：确认后把该角色（称呼 + 别名）移入黑名单，重新解析时不再识别
                    Button {
                        blacklistTarget = role
                        showBlacklistConfirm = true
                    } label: {
                        Image(systemName: "hand.raised.fill").font(.caption).foregroundColor(.orange)
                    }
                    .buttonStyle(.borderless)
                    // 修改：打开 sheet 同时改称呼与性别
                    Button {
                        editingRole = role
                        editNameText = role.canonicalName
                        editGender = role.gender
                        showEditSheet = true
                    } label: {
                        Image(systemName: "pencil").font(.caption)
                    }
                    .buttonStyle(.borderless)
                    Button {
                        deleteTarget = .role(role)
                        showDeleteConfirm = true
                    } label: {
                        Image(systemName: "trash").font(.caption).foregroundColor(.red)
                    }
                    .buttonStyle(.borderless)
                }
            }
            if !role.aliases.isEmpty {
                Text("别名：" + role.aliases.joined(separator: "、"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            // 前 10 个角色可单独选择声音（多选模式下隐藏）
            // 数据源 = 系统声 + 已下载/已导入的离线包，二者统一编码进 voiceOverrides
            if !multiSelectMode, index < 10,
               !voiceOptions.isEmpty || !offlineVoiceOptions.isEmpty {
                HStack(spacing: 8) {
                    Picker("声音", selection: voiceBinding(for: role)) {
                        Text("自动分配").tag(String?.none)
                        ForEach(voiceOptions, id: \.identifier) { v in
                            Text(v.name).tag(String?.some(v.identifier))
                        }
                        ForEach(offlineVoiceOptions) { opt in
                            Text(opt.name).tag(String?.some(opt.id))
                        }
                    }
                    .font(.caption)
                    // 预听：按当前选择（含自动分配与性别音高补偿）实际说一句「你好，我是中国人」
                    Button {
                        previewVoice(for: role)
                    } label: {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.caption)
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onLongPressGesture {
            // 长按任一角色：进入多选模式并选中该角色
            multiSelectMode = true
            selectedRoleIds = [role.id]
        }
        .onTapGesture {
            if multiSelectMode {
                if selectedRoleIds.contains(role.id) {
                    selectedRoleIds.remove(role.id)
                } else {
                    selectedRoleIds.insert(role.id)
                }
            }
        }
        .background(multiSelectMode && selectedRoleIds.contains(role.id) ? Color.accentColor.opacity(0.08) : Color.clear)
    }

    /// 批量删除确认框文案
    private var multiDeleteMessage: String {
        "确认要删除 \(selectedRoleIds.count) 个角色吗？被删角色的台词将改由旁白（中性声）朗读。"
    }

    private func executeMultiDelete() {
        analysis.roles.removeAll { selectedRoleIds.contains($0.id) }
        for i in analysis.segments.indices where analysis.segments[i].characterId.map({ selectedRoleIds.contains($0) }) == true {
            analysis.segments[i].characterId = nil
        }
        onEdited?()
        multiSelectMode = false
        selectedRoleIds = []
    }

    // MARK: 黑白名单面板

    private var blacklistPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            panelHeader("黑名单（\(blacklisted.count)）")
            Text("名单中的词永远不会被识别为人名。重新「整体解析」后生效。")
                .font(.caption2).foregroundColor(.secondary)
            wordEditor(text: $newBlackWord, placeholder: "输入要屏蔽的词") { addWord(newBlackWord, to: .blacklist) }
            ForEach(blacklisted, id: \.self) { w in
                wordRow(w, list: .blacklist)
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
                wordRow(w, list: .whitelist)
            }
        }
        .padding(12)
    }

    // MARK: 自定义规则面板（≤20 条）

    private var rulesPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            panelHeader("自定义规则（\(rules.count)/20）")
            Text("朗读时把「匹配文本」替换为「替换文本」，本地/云端朗读均生效，保存后立即应用。")
                .font(.caption2).foregroundColor(.secondary)
            Button {
                ruleFindDraft = ""
                ruleReplaceDraft = ""
                editingRuleFind = nil
                showRuleAlert = true
            } label: {
                Label("添加新规则", systemImage: "plus.circle.fill")
                    .font(.caption)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(rules.count >= 20)
            if rules.count >= 20 {
                Text("已达上限 20 条，请先删除不需要的规则。")
                    .font(.caption2).foregroundColor(.secondary)
            }
            ForEach(rules) { rule in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("「\(rule.find)」")
                            .font(.caption.bold())
                        Text("→ 朗读「\(rule.replace)」")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button {
                        ruleFindDraft = rule.find
                        ruleReplaceDraft = rule.replace
                        editingRuleFind = rule.find
                        showRuleAlert = true
                    } label: {
                        Image(systemName: "pencil").font(.caption)
                    }
                    .buttonStyle(.borderless)
                    Button {
                        deleteTarget = .rule(rule)
                        showDeleteConfirm = true
                    } label: {
                        Image(systemName: "trash").font(.caption).foregroundColor(.red)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(12)
    }

    // MARK: 通用小组件

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

    private func wordRow(_ word: String, list: Panel) -> some View {
        HStack {
            Text(word)
            Spacer()
            Button {
                deleteTarget = .word(word, list)
                showDeleteConfirm = true
            } label: {
                Image(systemName: "trash").font(.caption).foregroundColor(.red)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    // MARK: 删除确认

    private var deleteConfirmMessage: String {
        switch deleteTarget {
        case .role(let role):
            return "删除角色「\(role.canonicalName)」后，其所有台词将改由旁白（中性声）朗读。确定删除吗？"
        case .word(let word, let list):
            return list == .blacklist
                ? "从黑名单移除「\(word)」后，该词将不再被强制屏蔽。确定删除吗？"
                : "从白名单移除「\(word)」后，该词将不再被强制识别为人名。确定删除吗？"
        case .rule(let rule):
            return "删除规则「\(rule.find) → \(rule.replace)」后立即生效。确定删除吗？"
        case nil:
            return ""
        }
    }

    private func executeDelete() {
        switch deleteTarget {
        case .role(let role):
            analysis.roles.removeAll { $0.id == role.id }
            for i in analysis.segments.indices where analysis.segments[i].characterId == role.id {
                analysis.segments[i].characterId = nil
            }
            onEdited?()
        case .word(let word, let list):
            if list == .blacklist {
                onListsChanged?(blacklisted.filter { $0 != word }, whitelisted)
            } else {
                onListsChanged?(blacklisted, whitelisted.filter { $0 != word })
            }
        case .rule(let rule):
            let updated = rules.filter { $0.id != rule.id }
            onRulesChanged?(updated)
        case nil:
            break
        }
        deleteTarget = nil
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

    // MARK: 规则操作

    private func commitRule() {
        let find = ruleFindDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let replace = ruleReplaceDraft
        guard !find.isEmpty else { return }
        var updated = rules
        if let editing = editingRuleFind, let idx = updated.firstIndex(where: { $0.id == editing }) {
            updated[idx] = CustomRule(find: find, replace: replace)
        } else {
            // 同匹配文本的规则直接更新，避免重复
            if let idx = updated.firstIndex(where: { $0.id == find }) {
                updated[idx] = CustomRule(find: find, replace: replace)
            } else {
                updated.append(CustomRule(find: find, replace: replace))
            }
        }
        onRulesChanged?(updated)
    }

    // MARK: 角色声音

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

    /// 预听该角色当前生效的声音：手动指定离线包 → 离线合成试听；系统声/自动分配 → AVSpeech 试听。
    private func previewVoice(for role: CharacterRole) {
        let chosen = voiceOverrides[role.canonicalName]
        // 手工选了离线包：直接用该包 + 编号合成一句试听，走 VoicePreviewer 的音频播放通道
        if let chosen, let offline = VoiceChoice.decode(chosen) {
            Task { @MainActor in
                if let wav = await offlineMgr.synthesizePreview(
                    text: "你好，我是中国人",
                    packId: offline.packId, sid: offline.sid, speed: 1.0) {
                    VoicePreviewer.shared.playAudio(wav)
                } else {
                    // 离线合成无可用音频（引擎未就绪/产出静音）时回退系统声试听，避免点击无反应
                    previewSystemVoice(for: role, chosen: nil)
                }
            }
            return
        }
        // 自动分配时若离线朗读已启用，也预听实际会用的离线音色（按性别池分配）
        if chosen == nil, settings.offlineTTSEnabled {
            Task { @MainActor in
                let maleSIDs = settings.offlineTTSMaleSIDs.split(separator: ",")
                    .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
                let femaleSIDs = settings.offlineTTSFemaleSIDs.split(separator: ",")
                    .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
                if let wav = await offlineMgr.synthesizeForCharacter(
                    text: "你好，我是中国人", characterId: "preview_\(role.id)",
                    gender: role.gender, packGenders: settings.offlinePackGenders,
                    maleSIDs: maleSIDs, femaleSIDs: femaleSIDs, speed: 1.0) {
                    VoicePreviewer.shared.playAudio(wav)
                    return
                }
                previewSystemVoice(for: role, chosen: nil)
            }
            return
        }
        previewSystemVoice(for: role, chosen: chosen)
    }

    private func previewSystemVoice(for role: CharacterRole, chosen: String?) {
        let identifier = chosen
            ?? TTSPlayer.assignVoicesAndPitches(roles: [role]).voices[role.id]?.identifier
        let voice = identifier.flatMap { AVSpeechSynthesisVoice(identifier: $0) }
        let pitch = TTSPlayer.assignVoicesAndPitches(roles: [role]).pitches[role.id] ?? 1.0
        VoicePreviewer.shared.preview(voice, pitch: pitch)
    }

    // MARK: 修改角色（称呼 + 性别）

    private var editRoleSheet: some View {
        NavigationStack {
            Form {
                Section("角色称呼") {
                    TextField("称呼", text: $editNameText)
                        .autocorrectionDisabled()
                }
                Section("性别（用于自动选声匹配）") {
                    Picker("性别", selection: $editGender) {
                        Text("男").tag(Gender.male)
                        Text("女").tag(Gender.female)
                        Text("中性").tag(Gender.neutral)
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    Text("原称呼将保留为该角色的别名之一，朗读时同一角色仍使用同一声音；性别会用于离线/系统声音按男声、女声自动匹配。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("修改角色")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { showEditSheet = false }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") { commitEdit() }
                }
            }
        }
    }

    private func commitEdit() {
        let newName = editNameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target = editingRole, !newName.isEmpty,
              let idx = analysis.roles.firstIndex(where: { $0.id == target.id }) else { return }
        let old = analysis.roles[idx].canonicalName
        let genderChanged = analysis.roles[idx].gender != editGender
        analysis.roles[idx].canonicalName = newName
        analysis.roles[idx].gender = editGender
        if old != newName, !analysis.roles[idx].aliases.contains(old) {
            analysis.roles[idx].aliases.append(old)
        }
        // 称呼变化：把该角色的手工声音覆盖（按旧称呼 key）迁移到新称呼，避免静默失效
        if old != newName, let v = voiceOverrides[old] {
            var updated = voiceOverrides
            updated.removeValue(forKey: old)
            updated[newName] = v
            onVoiceChanged?(updated)
        }
        // 性别变化：清掉离线语音包分配缓存，下次朗读按新性别重新匹配声音
        if genderChanged {
            OfflineTTSManager.shared.resetAssignments()
        }
        onEdited?()
        showEditSheet = false
        editingRole = nil
    }

    // MARK: 拉黑角色

    private var blacklistConfirmMessage: String {
        guard let role = blacklistTarget else { return "" }
        return "将「\(role.canonicalName)」及其别名移入黑名单后，重新「整体解析」时该称呼将永不识别为角色；其现有台词改为旁白（中性声）朗读。确定拉黑吗？"
    }

    private func executeBlacklist() {
        guard let role = blacklistTarget else { return }
        let name = role.canonicalName
        analysis.roles.removeAll { $0.id == role.id }
        for i in analysis.segments.indices where analysis.segments[i].characterId == role.id {
            analysis.segments[i].characterId = nil
        }
        // 称呼 + 别名一并移入黑名单：重新解析时永不识别为该角色
        let words = [name] + role.aliases
        var newBlack = blacklisted
        for w in words where !newBlack.contains(w) {
            newBlack.append(w)
        }
        // 黑名单优先：若其中某词碰巧在白名单，移出白名单
        let newWhite = whitelisted.filter { !words.contains($0) }
        onListsChanged?(newBlack, newWhite)
        onEdited?()
        blacklistTarget = nil
    }

    // MARK: 从文本导入角色定义

    private var textImportSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                Text("格式（每段一个人物）：")
                    .font(.caption).foregroundColor(.secondary)
                Text("人物：慕容衍，性别：男\n别称：慕容公子、殿下")
                    .font(.caption.monospaced())
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                TextEditor(text: $importText)
                    .frame(minHeight: 180)
                    .overlay(
                        Group {
                            if importText.isEmpty {
                                Text("在此粘贴角色定义…")
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                    .padding(8)
                                    .allowsHitTesting(false)
                            }
                        }
                    )
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(.systemGray4)))
                Button {
                    requestImport(parseImportedRoles(importText))
                } label: {
                    Label("解析并导入", systemImage: "tray.and.arrow.down.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
            }
            .padding()
            .navigationTitle("从文本导入角色")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { showTextImportSheet = false }
                }
            }
            // Sheet 内也能弹导入方式选择（root 上那份在 Sheet 打开时不生效）
            .confirmationDialog(
                "选择导入方式",
                isPresented: $showImportModeDialog,
                titleVisibility: .visible
            ) {
                Button("替换所有已存在角色", role: .destructive) { applyImport(replaceExisting: true) }
                Button("新增到现有角色") { applyImport(replaceExisting: false) }
                Button("取消", role: .cancel) { pendingImport = nil }
            } message: {
                Text("「替换」将删除当前所有已存在角色，改用导入的角色；「新增」将导入角色合并进现有角色（按称呼匹配）。")
            }
        }
    }

    /// 解析「人物：X，性别：男/女 + 别称：…」格式的文本。容错：性别缺失视为中性；
    /// 别称行支持顿号/逗号分隔多个；未写「人物」前缀但含性别/单独成行的名字也可识别为人物行。
    private func parseImportedRoles(_ text: String) -> [(name: String, gender: Gender, aliases: [String])] {
        var result: [(name: String, gender: Gender, aliases: [String])] = []
        var current: (name: String, gender: Gender, aliases: [String])? = nil

        func flush() {
            if let c = current, !c.name.isEmpty { result.append(c) }
            current = nil
        }
        func parseGender(_ s: String) -> Gender {
            if s.contains("女") { return .female }
            if s.contains("男") { return .male }
            return .neutral
        }
        func parsePersonLine(_ line: String) {
            flush()
            // 去掉「人物」前缀与冒号
            var body = line
            if body.hasPrefix("人物") { body = String(body.dropFirst(2)) }
            body = body.trimmingCharacters(in: CharacterSet(charactersIn: "：: "))
            var name = body
            var gender: Gender = .neutral
            if let r = body.range(of: "性别") {
                let before = String(body[..<r.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: "，, "))
                let after = String(body[r.lowerBound...])
                name = before
                gender = parseGender(after)
            } else if body.hasSuffix("男") || body.hasSuffix("女") {
                gender = body.hasSuffix("女") ? .female : .male
                name = String(body.dropLast(1)).trimmingCharacters(in: CharacterSet(charactersIn: "，, "))
            }
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: "，, "))
            if !name.isEmpty { current = (name, gender, []) }
        }

        for rawLine in importText.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("人物") {
                parsePersonLine(line)
            } else if line.hasPrefix("别称") || line.hasPrefix("别名") {
                var body = line
                if body.hasPrefix("别称") || body.hasPrefix("别名") { body = String(body.dropFirst(2)) }
                body = body.trimmingCharacters(in: CharacterSet(charactersIn: "：: "))
                let aliases = body.split(whereSeparator: { "，,、;；/ ".contains($0) })
                    .map(String.init).filter { !$0.isEmpty }
                current?.aliases.append(contentsOf: aliases)
            } else if line.contains("性别") {
                parsePersonLine(line)
            }
        }
        flush()
        return result
    }

    /// 导入入口：解析成功后先暂存，弹出「替换 / 新增」二选一
    private func requestImport(_ parsed: [(name: String, gender: Gender, aliases: [String])]) {
        guard !parsed.isEmpty else {
            importSummary = "没有解析到任何角色。请检查格式：\n人物：X，性别：男/女\n别称：…\n或表格含「姓名」「性别」列。"
            return
        }
        pendingImport = parsed
        showImportModeDialog = true
    }

    /// 执行导入：replaceExisting = true 删除所有已存在角色用导入替代；false 合并进现有角色。
    private func applyImport(replaceExisting: Bool) {
        guard let parsed = pendingImport else { return }
        pendingImport = nil

        if replaceExisting {
            let oldRoles = analysis.roles
            var newRoles: [CharacterRole] = []
            for (i, p) in parsed.enumerated() {
                let hint: String? = p.gender == .male ? "male" : (p.gender == .female ? "female" : "neutral")
                newRoles.append(CharacterRole(
                    id: "role_imp_\(i)_\(p.name)",
                    canonicalName: p.name,
                    aliases: p.aliases,
                    gender: p.gender,
                    voiceHint: hint
                ))
            }
            // 关键：旧分段引用的是旧角色 id。按称呼（先精确名、再别名）把旧 id 重映射到新角色，
            // 否则朗读分声与手动声音配置全部失配。匹配不上的降级为旁白。
            var idMap: [String: String?] = [:]
            for old in oldRoles {
                var mapped: String?? = .some(nil)
                if let exact = newRoles.first(where: { $0.canonicalName == old.canonicalName }) {
                    mapped = .some(exact.id)
                } else if let viaAlias = newRoles.first(where: {
                    $0.aliases.contains(old.canonicalName) || old.aliases.contains($0.canonicalName)
                }) {
                    mapped = .some(viaAlias.id)
                }
                idMap[old.id] = mapped
            }
            for i in analysis.segments.indices {
                if let oldId = analysis.segments[i].characterId {
                    analysis.segments[i].characterId = idMap[oldId] ?? nil
                }
            }
            analysis.roles = newRoles
            visibleRoleCount = 10
            importSummary = "已删除原有角色，替换为导入的 \(newRoles.count) 个角色（原台词归属已按称呼迁移）。"
        } else {
            var created = 0, merged = 0
            for p in parsed {
                if let idx = analysis.roles.firstIndex(where: {
                    $0.canonicalName == p.name || $0.aliases.contains(p.name)
                }) {
                    var role = analysis.roles[idx]
                    // 其他角色的正式名称不能作为本角色的别名（防止「吴七（伪装）」把两人混成一人）
                    let otherNames = Set(analysis.roles.filter { $0.id != role.id }.map { $0.canonicalName })
                    for a in p.aliases + [p.name]
                    where a != role.canonicalName && !role.aliases.contains(a) && !otherNames.contains(a) {
                        role.aliases.append(a)
                    }
                    if p.gender != .neutral {
                        role.gender = p.gender
                        role.voiceHint = p.gender == .male ? "male" : "female"
                    }
                    analysis.roles[idx] = role
                    merged += 1
                } else {
                    // 新建角色的别名同样不能撞其他角色的正式名称
                    let otherNames = Set(analysis.roles.map { $0.canonicalName })
                    let safeAliases = p.aliases.filter { !otherNames.contains($0) }
                    let hint: String? = p.gender == .male ? "male" : (p.gender == .female ? "female" : "neutral")
                    analysis.roles.append(CharacterRole(
                        id: "role_imp_\(analysis.roles.count)_\(p.name)",
                        canonicalName: p.name,
                        aliases: safeAliases,
                        gender: p.gender,
                        voiceHint: hint
                    ))
                    created += 1
                }
            }
            importSummary = "导入完成：新建 \(created) 个角色，合并 \(merged) 个已有角色。"
        }
        onEdited?()
        showTextImportSheet = false
    }

    // MARK: 从表格（.xlsx）导入角色

    private var xlsxType: UTType {
        UTType(filenameExtension: "xlsx") ?? .data
    }

    private func importRolesFromXlsx(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let parsed = XlsxRoleParser().parseRoles(from: url)
        guard !parsed.isEmpty else {
            importSummary = "未能从该表格解析到角色。请确认是人物解析表（含「姓名」「性别」列的工作表）。"
            return
        }
        requestImport(parsed.map { (name: $0.name, gender: $0.gender, aliases: $0.aliases) })
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

/// 系统分享面板（UIActivityViewController 的 SwiftUI 包装）。
private struct ActivityView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
