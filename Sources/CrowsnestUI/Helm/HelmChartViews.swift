import CrowsnestKit
import SwiftUI

/// Charts of all Helm repositories, like Lens' Helm › Charts.
struct HelmChartsView: View {
    @Environment(ClusterModel.self) private var model
    @State private var catalog = HelmCatalog.shared
    @State private var selection: HelmChart.ID?
    @State private var sortOrder = [KeyPathComparator(\HelmChart.name, comparator: .localizedStandard)]
    @State private var showRepositories = false

    private var rows: [HelmChart] {
        catalog.charts(matching: model.searchText).sorted(using: sortOrder)
    }

    private var selectedChart: HelmChart? { selection.flatMap { id in catalog.charts.first { $0.id == id } } }

    var body: some View {
        let rows = self.rows
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { chart in
                HStack(spacing: 6) {
                    Text(chart.name)
                    if chart.latest.deprecated {
                        Text("deprecated").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .width(min: 120, ideal: 200)
            TableColumn("Description", value: \.latest.description) { chart in
                Text(chart.latest.description).foregroundStyle(.secondary).help(chart.latest.description)
            }
            .width(min: 160, ideal: 380)
            TableColumn("Version", value: \.latest.version, comparator: SemVerComparator()) { chart in
                Text(chart.latest.version).monospacedDigit()
            }
            .width(min: 60, ideal: 90)
            TableColumn("App Version", value: \.latest.appVersion, comparator: SemVerComparator()) { chart in
                Text(chart.latest.appVersion.isEmpty ? "–" : chart.latest.appVersion).monospacedDigit()
            }
            .width(min: 60, ideal: 100)
            TableColumn("Repository", value: \.repository.name, comparator: .localizedStandard) { chart in
                Text(chart.repository.name)
            }
            .width(min: 80, ideal: 140)
        }
        .overlay { overlay }
        .inspector(isPresented: Binding(get: { selectedChart != nil }, set: { if !$0 { selection = nil } })) {
            Group {
                if let chart = selectedChart { HelmChartDetailView(chart: chart, onClose: { selection = nil }) }
            }
            .inspectorColumnWidth(min: 420, ideal: 620, max: 1100)
        }
        .toolbar {
            ToolbarItem {
                Button("Repositories", systemImage: "externaldrive.connected.to.line.below") { showRepositories = true }
                    .help("Manage Helm repositories")
            }
        }
        .sheet(isPresented: $showRepositories) {
            NavigationStack {
                HelmRepositoriesView()
                    .navigationTitle("Helm Repositories")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showRepositories = false } } }
            }
            .frame(minWidth: 560, minHeight: 420)
        }
        .navigationTitle("Helm Charts")
        #if os(macOS)
        .navigationSubtitle(subtitle(count: rows.count))
        #endif
        .task { await catalog.loadIfNeeded() }
    }

    private func subtitle(count: Int) -> String {
        var parts = ["\(count) charts", "\(catalog.repositories.count) repositories"]
        if catalog.isLoading { parts.append("loading…") } else if let date = catalog.lastUpdate {
            parts.append("updated \(date.formatted(date: .omitted, time: .shortened))")
        }
        if !catalog.errors.isEmpty { parts.append("\(catalog.errors.count) failed") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var overlay: some View {
        if catalog.repositories.isEmpty {
            ContentUnavailableView {
                Label("No Helm Repositories", systemImage: "books.vertical")
            } description: {
                Text("Add a chart repository to browse its charts.")
            } actions: {
                Button("Add Repository…") { showRepositories = true }
            }
        } else if catalog.charts.isEmpty && catalog.isLoading {
            ProgressView("Loading repository indexes…")
        } else if catalog.charts.isEmpty && !catalog.errors.isEmpty {
            ContentUnavailableView("Loading failed", systemImage: "exclamationmark.triangle",
                                   description: Text(catalog.errors.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")))
        } else if rows.isEmpty && !model.searchText.isEmpty {
            ContentUnavailableView.search(text: model.searchText)
        }
    }
}

/// Orders version strings by SemVer in table columns.
struct SemVerComparator: SortComparator {
    var order: SortOrder = .forward
    func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let result = SemVer.compare(lhs, rhs)
        guard order == .reverse else { return result }
        return result == .orderedAscending ? .orderedDescending : result == .orderedDescending ? .orderedAscending : .orderedSame
    }
}

/// Details of a chart: versions, metadata, README and default values.
struct HelmChartDetailView: View {
    @Environment(ClusterModel.self) private var model
    let chart: HelmChart
    var onClose: () -> Void

    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview", readme = "README", values = "Default Values", versions = "Versions"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .overview
    @State private var versionID: String = ""
    @State private var files: HelmChartFiles?
    @State private var filesError: String?
    @State private var copied = false

    private var version: HelmChartVersion { chart.versions.first { $0.id == versionID } ?? chart.latest }

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("View", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            Divider()
            switch tab {
            case .overview: overview
            case .readme: fileView(files?.readme, empty: "No README") { MarkdownText(text: $0) }
            case .values: fileView(files?.values, empty: "No values.yaml") { ReadOnlyYAML(text: $0) }
            case .versions: versions
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .id(chart.id)
        .task(id: version.id) { await loadFiles() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            ChartIcon(url: version.icon).frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(chart.name).font(.headline).textSelection(.enabled)
                HStack(spacing: 6) {
                    Text("Helm Chart"); Text("·"); Text(chart.repository.name)
                    if version.deprecated { Text("·"); Text("deprecated").foregroundStyle(.orange) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Version", selection: Binding(get: { version.id }, set: { versionID = $0 })) {
                ForEach(chart.versions) { Text($0.version).tag($0.id) }
            }
            .labelsHidden()
            .fixedSize()
            .help("Chart version")
            ForEach(Extensions.registered, id: \.id) { ext in
                if let actions = ext.helmChartActions(chart: chart, version: version, model: model) { actions }
            }
            Menu {
                Button("Copy Install Command", systemImage: "terminal") {
                    Pasteboard.copy(HelmCatalog.shared.installCommand(for: version, in: chart.repository, namespace: model.namespace))
                    model.toast = "Install command copied"
                }
                if let url = HelmRepositories.archiveURL(of: version, in: chart.repository), url.scheme != "oci" {
                    Button("Copy Archive URL", systemImage: "link") { Pasteboard.copy(url.absoluteString) }
                }
                if let home = version.home.flatMap(URL.init(string:)) {
                    Link(destination: home) { Label("Open Home Page", systemImage: "safari") }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .borderlessMenuStyle()
            .fixedSize()
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .help("Close")
        }
        .padding(12)
    }

    private var overview: some View {
        Form {
            Section("Chart") {
                Row("Version", version.version)
                Row("App Version", version.appVersion.isEmpty ? "–" : version.appVersion)
                Row("Created", version.created.map { "\($0.formatted(date: .abbreviated, time: .shortened)) (\(KubeDate.age(since: $0)))" } ?? "–")
                if !version.description.isEmpty { Row("Description", version.description) }
                if let type = version.type { Row("Type", type) }
                if let kube = version.kubeVersion { Row("Kubernetes", kube, monospaced: true) }
                Row("Repository", "\(chart.repository.name) – \(chart.repository.url)")
            }
            if version.home != nil || !version.sources.isEmpty {
                Section("Links") {
                    if let home = version.home.flatMap(URL.init(string:)) { LabeledContent("Home") { Link(home.absoluteString, destination: home) } }
                    ForEach(version.sources, id: \.self) { source in
                        if let url = URL(string: source) { LabeledContent("Source") { Link(source, destination: url) } }
                    }
                }
            }
            if !version.keywords.isEmpty || !version.maintainers.isEmpty {
                Section("About") {
                    if !version.keywords.isEmpty { Row("Keywords", version.keywords.joined(separator: ", ")) }
                    if !version.maintainers.isEmpty { Row("Maintainers", version.maintainers.joined(separator: ", ")) }
                }
            }
            Section("Install") {
                Text(HelmCatalog.shared.installCommand(for: version, in: chart.repository, namespace: model.namespace))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }

    private var versions: some View {
        Table(chart.versions, selection: Binding(get: { version.id }, set: { if let id = $0 { versionID = id } })) {
            TableColumn("Version") { v in Text(v.version).monospacedDigit() }
            TableColumn("App Version") { v in Text(v.appVersion.isEmpty ? "–" : v.appVersion).monospacedDigit() }
            TableColumn("Created") { v in Text(v.created.map { KubeDate.age(since: $0) } ?? "–").monospacedDigit() }
        }
    }

    @ViewBuilder
    private func fileView(_ text: String?, empty: String, @ViewBuilder content: (String) -> some View) -> some View {
        if let text {
            content(text)
        } else if let filesError {
            ContentUnavailableView("Download failed", systemImage: "exclamationmark.triangle", description: Text(filesError))
        } else if files != nil {
            ContentUnavailableView(empty, systemImage: "doc")
        } else {
            ProgressView("Downloading \(chart.name) \(version.version)…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func loadFiles() async {
        files = nil
        filesError = nil
        do {
            files = try await HelmCatalog.shared.files(for: version, in: chart.repository)
        } catch {
            filesError = error.localizedDescription
        }
    }
}

/// Chart icon from the index (falls back to a symbol).
private struct ChartIcon: View {
    let url: String?

    var body: some View {
        if let url = url.flatMap(URL.init(string:)), url.scheme == "https" {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                fallback
            }
        } else {
            fallback
        }
    }

    private var fallback: some View {
        Image(systemName: "shippingbox").font(.title2).foregroundStyle(.secondary)
    }
}

/// Lightweight Markdown rendering for READMEs: block structure (headings, code blocks, lists) with inline styling,
/// lazily laid out so large READMEs stay fast.
struct MarkdownText: View {
    let text: String

    enum Block: Hashable {
        case heading(Int, String), code(String), paragraph(String)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .heading(let level, let title):
                        Text(Self.inline(title))
                            .font(level <= 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                            .padding(.top, 4)
                    case .code(let code):
                        Text(code)
                            .font(.system(.caption, design: .monospaced))
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    case .paragraph(let paragraph):
                        Text(Self.inline(paragraph))
                    }
                }
            }
            .textSelection(.enabled)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        func flush() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph = []
        }
        // HTML comments (e.g. "<!-- app-name: … -->") aren't shown.
        let visible = text.replacing(/<!--[\s\S]*?-->/, with: "")
        for raw in visible.components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\r", with: "")
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if let open = code {
                    blocks.append(.code(open.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                }
                continue
            }
            if code != nil { code!.append(line); continue }
            if line.hasPrefix("#") {
                let level = line.prefix { $0 == "#" }.count
                let title = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
                if level <= 6, !title.isEmpty { flush(); blocks.append(.heading(level, title)); continue }
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { flush() } else { paragraph.append(line) }
        }
        if let open = code { blocks.append(.code(open.joined(separator: "\n"))) }
        flush()
        return blocks
    }
}

/// List of Helm repositories with add/remove (used in Settings and from the chart browser).
struct HelmRepositoriesView: View {
    @State private var catalog = HelmCatalog.shared
    @State private var name = ""
    @State private var url = ""
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                if catalog.repositories.isEmpty {
                    Text("No repositories yet.").foregroundStyle(.secondary)
                }
                ForEach(catalog.repositories) { repo in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(repo.name)
                                if catalog.isFromHelmCLI(repo) {
                                    Text("helm CLI").font(.caption2).foregroundStyle(.secondary)
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Color.secondary.opacity(0.15), in: Capsule())
                                }
                            }
                            Text(repo.url).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            if let error = catalog.errors[repo.name] {
                                Text(error).font(.caption).foregroundStyle(.red)
                            }
                        }
                        Spacer()
                        if !catalog.isFromHelmCLI(repo) {
                            Button(role: .destructive) { catalog.remove(repo) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .help("Remove \(repo.name)")
                        }
                    }
                }
            } header: {
                Text("Helm Repositories")
            } footer: {
                #if os(macOS)
                Text("Repositories of the helm CLI (helm repo add) are included automatically and can only be removed with helm.")
                #else
                Text("Charts are listed from each repository's index.yaml. OCI registries can't be browsed.")
                #endif
            }
            Section("Add Repository") {
                TextField("Name", text: $name, prompt: Text("bitnami"))
                TextField("URL", text: $url, prompt: Text("https://charts.bitnami.com/bitnami"))
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    .autocorrectionDisabled()
                HStack {
                    if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
                    Spacer()
                    Menu("Suggestions") {
                        ForEach(HelmCatalog.suggestions.filter { s in !catalog.repositories.contains { $0.name == s.name } }) { s in
                            Button(s.name) { name = s.name; url = s.url }
                        }
                    }
                    .fixedSize()
                    Button("Add") {
                        problem = catalog.add(name: name, url: url)
                        if problem == nil { name = ""; url = "" }
                    }
                    .disabled(name.isEmpty || url.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }
}
