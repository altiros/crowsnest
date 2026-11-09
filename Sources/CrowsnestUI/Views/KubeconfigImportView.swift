import CrowsnestKit
import SwiftUI
import UniformTypeIdentifiers

/// Buttons to import a kubeconfig from a file or the clipboard (used on iPadOS).
struct KubeconfigImportButtons: View {
    @Environment(ClusterModel.self) private var model
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
            Task {
                await model.loadKubeconfig()
                if let first = contexts.first { await model.selectContext(first) }
            }
        } catch {
            errorMessage = error.localizedDescription
            resultMessage = nil
        }
    }
}

/// Imported kubeconfig files with delete (iPadOS settings).
struct KubeconfigFilesSection: View {
    @Environment(ClusterModel.self) private var model
    @State private var files: [URL] = KubeconfigStore.files()

    var body: some View {
        Section {
            if files.isEmpty {
                Text("No kubeconfig imported yet").foregroundStyle(.secondary)
            }
            ForEach(files, id: \.self) { url in
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent)
                    let contexts = (try? KubeConfig.parse(String(contentsOf: url, encoding: .utf8)).contextNames) ?? []
                    Text(contexts.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .onDelete { offsets in
                for index in offsets { try? KubeconfigStore.remove(files[index]) }
                files = KubeconfigStore.files()
                Task { await model.loadKubeconfig() }
            }
            KubeconfigImportButtons()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        } header: {
            Text("kubeconfigs")
        } footer: {
            Text("Export with \"kubectl config view --raw --flatten --minify --context <name>\". The files are stored protected in the app container. exec auth plugins (aws, gcloud, kubelogin) are not available on the iPad.")
        }
        .onChange(of: model.kubeconfig?.contextNames) { files = KubeconfigStore.files() }
    }
}
