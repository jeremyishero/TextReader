import SwiftUI
import UniformTypeIdentifiers

struct DocumentListView: View {
    @EnvironmentObject var store: DocumentStore
    @State private var showImporter = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                if store.documents.isEmpty {
                    Text("还没有文档，点击右上角导入 txt / Word / PDF")
                        .foregroundColor(.secondary)
                }
                ForEach(store.documents) { doc in
                    NavigationLink {
                        ReadingView(item: doc)
                    } label: {
                        Label(doc.name, systemImage: icon(for: doc.fileType))
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
                }
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.plainText, .pdf, UTType(filenameExtension: "docx")!, .data],
            allowsMultipleSelection: false
        ) { result in
            if let url = try? result.get().first {
                Task { try? await store.importFile(from: url) }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    private func icon(for type: String) -> String {
        switch type {
        case "pdf": return "doc.fill"
        case "docx": return "doc.text.fill"
        default: return "doc.plaintext"
        }
    }
}
