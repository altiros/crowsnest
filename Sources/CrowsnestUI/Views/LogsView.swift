import CrowsnestKit
import SwiftUI

/// Pod logs with container selection, tail, follow, previous and filter.
struct LogsView: View {
    @Environment(ClusterModel.self) private var model
    let pod: KubeObject

    @State private var container: String = ""
    @State private var tailLines: Int = 500
    @State private var follow = true
    @State private var previous = false
    @State private var timestamps = false
    @State private var filter = ""
    @State private var lines: [String] = []
    @State private var text = ""
    @State private var error: String?
    @State private var isStreaming = false

    private static let maxLines = 20_000

    private struct RequestKey: Hashable {
        var container: String, tail: Int, follow: Bool, previous: Bool, timestamps: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(6)
            }
            CodeTextView(text: $text, scrollToEnd: follow)
        }
        .onAppear {
            if container.isEmpty { container = PodStatus.containerNames(of: pod, includeInit: false).first ?? "" }
        }
        .onChange(of: filter) { render() }
        .task(id: RequestKey(container: container, tail: tailLines, follow: follow, previous: previous, timestamps: timestamps)) {
            await load()
        }
    }

    private var controls: some View {
        VStack(spacing: 6) {
            HStack {
                Picker("Container", selection: $container) {
                    ForEach(PodStatus.containerNames(of: pod), id: \.self) { Text($0).tag($0) }
                }
                .frame(maxWidth: 240)
                Picker("Lines", selection: $tailLines) {
                    Text("100").tag(100)
                    Text("500").tag(500)
                    Text("2000").tag(2000)
                    Text("10000").tag(10000)
                }
                .frame(maxWidth: 140)
                Spacer()
                if isStreaming {
                    ProgressView().controlSize(.small)
                }
            }
            HStack {
                Toggle("Follow", isOn: $follow)
                #if os(macOS)
                Toggle("Previous Container", isOn: $previous)
                #else
                Toggle("Previous", isOn: $previous)  // the previous container's logs
                #endif
                Toggle("Timestamps", isOn: $timestamps)
                Spacer()
                TextField("Filter", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
                Button("Copy", systemImage: "doc.on.doc") { Pasteboard.copy(text) }
                    .labelStyle(.iconOnly)
            }
            #if os(macOS)
            .toggleStyle(.checkbox)
            #else
            .toggleStyle(.button)  // switches with long labels wrap in the inspector
            #endif
        }
        .controlSize(.small)
        .padding(8)
    }

    private func load() async {
        guard let client = model.client, let namespace = pod.namespace, !container.isEmpty else { return }
        error = nil
        lines = []
        render()
        let options = KubeClient.LogOptions(container: container, tailLines: tailLines, previous: previous, timestamps: timestamps)
        if follow && !previous {
            isStreaming = true
            defer { isStreaming = false }
            do {
                for try await batch in client.followLogs(pod: pod.name, namespace: namespace, options: options) {
                    append(batch)
                }
            } catch {
                self.error = error.localizedDescription
            }
        } else {
            do {
                let log = try await client.logs(pod: pod.name, namespace: namespace, options: options)
                var all = log.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                if all.last == "" { all.removeLast() }
                append(all)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func append(_ batch: [String]) {
        lines.append(contentsOf: batch)
        if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
        render()
    }

    private func render() {
        let query = filter.trimmingCharacters(in: .whitespaces)
        let visible = query.isEmpty ? lines : lines.filter { $0.localizedCaseInsensitiveContains(query) }
        text = visible.joined(separator: "\n")
    }
}
