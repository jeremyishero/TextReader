import SwiftUI
import UniformTypeIdentifiers

struct DocumentListView: View {
    @EnvironmentObject var store: DocumentStore
    @State private var showImporter = false
    @State private var showSettings = false
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                if store.documents.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("还没有文档")
                            .font(.headline)
                        Text("点击右上角 + 号导入 txt / docx / pdf，导入后会自动提取文本并出现在列表中。")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                ForEach(store.documents) { doc in
                    NavigationLink {
                        ReadingView(item: doc)
                    } label: {
                        HStack {
                            Label(doc.name, systemImage: icon(for: doc.fileType))
                            Spacer()
                            if doc.ocrUsed == true {
                                Text("OCR")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .onDelete { store.delete($0) }
            }
            .navigationTitle("我的文档")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showImporter = true } label: { Image(systemName: "plus") }
                        .disabled(isImporting)
                }
            }
        }
        .overlay {
            // 规范：>1 秒的操作显示进度框；成功/静默回退显示轻提示；失败弹 Alert 说明准确原因
            if isImporting {
                BusyHUD(title: "正在导入并解析文件…")
            } else if let toast {
                ToastView(text: toast)
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.plainText, .pdf, UTType(filenameExtension: "docx")!, .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                importDocument(url)
            case .failure(let error):
                // 用户主动取消选择：静默返回，不算异常
                guard (error as? CocoaError)?.code != .userCancelled else { return }
                errorMessage = "打开文件选择器失败：\(error.localizedDescription)"
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .alert(
            "导入失败",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: 导入

    private func importDocument(_ url: URL) {
        isImporting = true
        Task {
            do {
                try await store.importFile(from: url)
                isImporting = false
                showToast("导入成功，已加入文档列表")
            } catch {
                isImporting = false
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: 轻提示

    private func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled { toast = nil }
        }
    }

    private func icon(for type: String) -> String {
        switch type {
        case "pdf": return "doc.fill"
        case "docx": return "doc.text.fill"
        default: return "doc.plaintext"
        }
    }
}
