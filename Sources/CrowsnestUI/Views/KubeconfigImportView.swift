import CrowsnestKit
import SwiftUI
import UniformTypeIdentifiers

/// Buttons to import a kubeconfig from a file or the clipboard (sandboxed: iPadOS, Mac App Store).
struct KubeconfigImportButtons: View {
    /// Missing in the macOS Settings window – the main window then reloads via `KubeconfigStore.didChange`.
    @Environment(ClusterModel.self) private var model: ClusterModel?
    @State private var showImporter = false
    @State private var resultMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Button("Import File…", systemImage: "doc.badge.plus") { showImporter = true }
                    .buttonStyle(.borderedProminent)
                Button("From Clipboard", systemImage: "doc.on.clipboard") { importFromClipboard() }
                    .buttonStyle(.bordered)
            }
            if let resultMessage {
                Text(resultMessage).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center)
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.yaml, .plainText, .data, .item],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                handle { try urls.map { try KubeconfigStore.importConfig(from: $0) } }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    private func importFromClipboard() {
        guard let text = Pasteboard.string, !text.isEmpty else {
            errorMessage = "The clipboard contains no text."
            return
        }
        handle { [try KubeconfigStore.importConfig(text: text, suggestedName: "kubeconfig")] }
    }

    private func handle(_ work: () throws -> [KubeconfigStore.ImportResult]) {
        do {
            let results = try work()
            let contexts = results.flatMap(\.contexts)
            resultMessage = "Imported: \(contexts.joined(separator: ", "))"
                + (results.flatMap(\.warnings).isEmpty ? "" : "\n" + results.flatMap(\.warnings).joined(separator: "\n"))
            errorMessage = nil
            if let model {
                Task {
                    await model.loadKubeconfig()
                    if let first = contexts.first { await model.selectContext(first) }
                }
            } else {
                NotificationCenter.default.post(name: KubeconfigStore.didChange, object: nil)
            }
        } catch {
            errorMessage = error.localizedDescription
            resultMessage = nil
        }
    }
}

/// Imported kubeconfig files with delete (settings when sandboxed).
struct KubeconfigFilesSection: View {
    @Environment(ClusterModel.self) private var model: ClusterModel?
    @State private var files: [URL] = KubeconfigStore.files()

    var body: some View {
        Section {
            if files.isEmpty {
                Text("No kubeconfig imported yet").foregroundStyle(.secondary)
            }
            ForEach(files, id: \.self) { url in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(url.lastPathComponent)
                        let contexts = (try? KubeConfig.parse(String(contentsOf: url, encoding: .utf8)).contextNames) ?? []
                        Text(contexts.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                    }
                    #if os(macOS)
                    Spacer()
                    Button("Remove", systemImage: "trash", role: .destructive) { remove([url]) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Remove this kubeconfig")
                    #endif
                }
            }
            .onDelete { offsets in remove(offsets.map { files[$0] }) }
            KubeconfigImportButtons()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        } header: {
            Text("kubeconfigs")
        } footer: {
            Text("Export with \"kubectl config view --raw --flatten --minify --context <name>\". The files are stored protected in the app container. exec auth plugins (aws, gcloud, kubelogin) are not available in this version.")
        }
        .onChange(of: model?.kubeconfig?.contextNames) { files = KubeconfigStore.files() }
        .onReceive(NotificationCenter.default.publisher(for: KubeconfigStore.didChange)) { _ in files = KubeconfigStore.files() }
    }

    private func remove(_ urls: [URL]) {
        for url in urls { try? KubeconfigStore.remove(url) }
        files = KubeconfigStore.files()
        if let model {
            Task { await model.loadKubeconfig() }
        } else {
            NotificationCenter.default.post(name: KubeconfigStore.didChange, object: nil)
        }
    }
}
