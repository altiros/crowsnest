import CrowsnestKit
import SwiftUI

/// Helm releases (read-only), like `helm list -a`.
struct HelmReleasesView: View {
    @Environment(ClusterModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let releases = model.helmReleases
        Table(releases, selection: $model.selectedHelmReleaseKey) {
            TableColumn("Name") { r in Text(r.name) }
                .width(min: 120, ideal: 180)
            TableColumn("Namespace") { r in Text(r.namespace) }
                .width(min: 80, ideal: 120)
            TableColumn("Chart") { r in Text(r.chart) }
                .width(min: 120, ideal: 180)
            TableColumn("App Version") { r in Text(r.appVersion.isEmpty ? "–" : r.appVersion) }
                .width(min: 70, ideal: 100)
            TableColumn("Revision") { r in Text(String(r.revision)).monospacedDigit() }
                .width(min: 50, ideal: 70)
            TableColumn("Status") { r in StatusLabel(text: r.status, tone: r.statusTone) }
                .width(min: 80, ideal: 110)
            TableColumn("Updated") { r in Text(KubeDate.age(since: r.lastDeployed)).monospacedDigit() }
                .width(min: 60, ideal: 80)
        }
        .overlay {
            if let error = model.helmError, releases.isEmpty {
                ContentUnavailableView("Loading failed", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if releases.isEmpty && model.lastRefresh != nil {
                ContentUnavailableView("No Helm Releases", systemImage: "shippingbox",
                                       description: Text(model.namespace.map { "in namespace \($0)" } ?? ""))
            }
        }
        .inspector(isPresented: Binding(
            get: { model.selectedHelmRelease != nil },
            set: { if !$0 { model.selectedHelmReleaseKey = nil } }
        )) {
            Group {
                if let release = model.selectedHelmRelease {
                    HelmReleaseDetailView(release: release)
                }
            }
            .inspectorColumnWidth(min: 420, ideal: 620, max: 1100)
        }
        .navigationTitle("Helm Releases")
        #if os(macOS)
        .navigationSubtitle("\(releases.count) releases")
        #endif
        .task(id: "\(model.contextName ?? "")|\(model.namespace ?? "*")") {
            while !Task.isCancelled {
                await model.loadHelm()
                let interval = max(ClusterModel.refreshInterval, 10)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }
}

struct HelmReleaseDetailView: View {
    @Environment(ClusterModel.self) private var model
    let release: HelmRelease

    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview", values = "Values", manifest = "Manifest", resources = "Resources", history = "History"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .overview

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "shippingbox").font(.title2).foregroundStyle(.secondary).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(release.name).font(.headline).textSelection(.enabled)
                    HStack(spacing: 6) {
                        Text("Helm Release"); Text("·"); Text(release.namespace)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                ForEach(Extensions.registered, id: \.id) { ext in
                    if let actions = ext.helmReleaseActions(release: release, model: model) { actions }
                }
                Button {
                    model.selectedHelmReleaseKey = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .help("Close")
            }
            .padding(12)
            Picker("View", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            Divider()
            switch tab {
            case .overview: HelmOverview(release: release)
            case .values: HelmValuesView(release: release)
            case .manifest: ReadOnlyYAML(text: release.manifest)
            case .resources: HelmResourcesView(release: release)
            case .history: HelmHistoryView(release: release)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .id(release.releaseKey)
    }
}

private struct HelmOverview: View {
    let release: HelmRelease

    var body: some View {
        Form {
            Section("Release") {
                LabeledContent("Status") { StatusLabel(text: release.status, tone: release.statusTone) }
                Row("Revision", String(release.revision))
                Row("Chart", release.chart)
                Row("App Version", release.appVersion.isEmpty ? "–" : release.appVersion)
                Row("Updated", release.lastDeployed.map { "\($0.formatted(date: .abbreviated, time: .shortened)) (\(KubeDate.age(since: $0)))" } ?? "–")
                Row("First Deployed", release.firstDeployed?.formatted(date: .abbreviated, time: .shortened) ?? "–")
                Row("Description", release.description.isEmpty ? "–" : release.description)
                if !release.chartDescription.isEmpty { Row("Chart Description", release.chartDescription) }
                Row("Stored In", "\(release.storageKind) \(release.storageName)", monospaced: true)
            }
            if !release.hooks.isEmpty {
                Section("Hooks") {
                    ForEach(Array(release.hooks.enumerated()), id: \.offset) { _, hook in
                        Row("\(hook.kind)/\(hook.name)", hook.events.joined(separator: ", "))
                    }
                }
            }
            if !release.notes.isEmpty {
                Section("Notes") {
                    Text(release.notes)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct HelmValuesView: View {
    let release: HelmRelease
    @State private var computed = false

    var body: some View {
        let text = (try? (computed ? release.computedValues : release.userValues).yamlString()) ?? ""
        VStack(spacing: 0) {
            HStack {
                Picker("Values", selection: $computed) {
                    Text("User-supplied").tag(false)
                    Text("Computed (with chart defaults)").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") { Pasteboard.copy(text) }
            }
            .controlSize(.small)
            .padding(8)
            if !computed && release.userValues == .object([:]) {
                ContentUnavailableView("No User-Supplied Values", systemImage: "slider.horizontal.3",
                                       description: Text("The release uses the chart defaults."))
            } else {
                ReadOnlyYAML(text: text, showsCopy: false)
            }
        }
    }
}

/// Read-only YAML with highlighting (and an optional copy button).
struct ReadOnlyYAML: View {
    let text: String
    var showsCopy = true
    @State private var binding = ""

    var body: some View {
        VStack(spacing: 0) {
            if showsCopy {
                HStack {
                    Spacer()
                    Button("Copy", systemImage: "doc.on.doc") { Pasteboard.copy(text) }
                }
                .controlSize(.small)
                .padding(8)
            }
            YAMLEditorView(text: $binding, isEditable: false)
        }
        .onAppear { binding = text }
        .onChange(of: text) { binding = text }
    }
}

private struct HelmResourcesView: View {
    @Environment(ClusterModel.self) private var model
    let release: HelmRelease

    var body: some View {
        let refs = release.resources
        List {
            Section("\(refs.count) objects rendered by the chart") {
                ForEach(refs) { ref in
                    Button {
                        model.reveal(ref, of: release)
                    } label: {
                        HStack {
                            Image(systemName: model.allKinds.first { $0.kind == ref.kind }?.symbol ?? "doc")
                                .foregroundStyle(.secondary).frame(width: 20)
                            Text(ref.kind).foregroundStyle(.secondary)
                            Text(ref.name).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if let ns = ref.namespace, ns != release.namespace {
                                Text(ns).font(.caption).foregroundStyle(.secondary)
                            }
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct HelmHistoryView: View {
    @Environment(ClusterModel.self) private var model
    let release: HelmRelease
    @State private var compareRevision: Int?
    @State private var compareValues = true

    var body: some View {
        let history = model.helmHistory(of: release)
        VStack(spacing: 0) {
            List(selection: $compareRevision) {
                ForEach(history) { r in
                    HStack(spacing: 10) {
                        Text("#\(r.revision)").monospacedDigit().frame(width: 34, alignment: .leading)
                        StatusLabel(text: r.status, tone: r.statusTone).frame(width: 100, alignment: .leading)
                        Text(r.chart).lineLimit(1)
                        Spacer()
                        Text(r.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text(KubeDate.age(since: r.lastDeployed)).font(.caption).foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                    .tag(r.revision)
                }
            }
            .frame(minHeight: 120, idealHeight: CGFloat(min(history.count, 6)) * 28 + 40, maxHeight: 220)
            Divider()
            if let rev = compareRevision, rev != release.revision, let old = history.first(where: { $0.revision == rev }) {
                HStack {
                    Text("Changes from #\(rev) to #\(release.revision)").font(.callout.weight(.semibold))
                    Spacer()
                    Picker("Compare", selection: $compareValues) {
                        Text("Values").tag(true)
                        Text("Manifest").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                .controlSize(.small)
                .padding(8)
                DiffView(lines: compareValues
                    ? TextDiff.unified(old: (try? old.userValues.yamlString()) ?? "", new: (try? release.userValues.yamlString()) ?? "")
                    : TextDiff.unified(old: old.manifest, new: release.manifest))
            } else {
                ContentUnavailableView("Compare Revisions", systemImage: "arrow.left.arrow.right",
                                       description: Text("Select an older revision to see what changed up to the current one."))
            }
        }
    }
}

/// Unified diff with colored lines.
struct DiffView: View {
    let lines: [TextDiff.Line]

    var body: some View {
        if lines.isEmpty {
            ContentUnavailableView("No Differences", systemImage: "equal.circle")
        } else {
            GeometryReader { geo in
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            row(line)
                        }
                    }
                    .padding(.vertical, 4)
                    // At least as wide as the viewport so line backgrounds span the whole width.
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
                    .textSelection(.enabled)
                }
                .defaultScrollAnchor(.topLeading)
            }
            .font(.system(size: 12, design: .monospaced))
        }
    }

    @ViewBuilder
    private func row(_ line: TextDiff.Line) -> some View {
        switch line {
        case .context(let text): rowText("  " + text, color: .primary, background: .clear)
        case .added(let text): rowText("+ " + text, color: .green, background: .green.opacity(0.12))
        case .removed(let text): rowText("- " + text, color: .red, background: .red.opacity(0.12))
        case .hunk(let text): rowText(text, color: .secondary, background: Color.secondary.opacity(0.08))
        }
    }

    private func rowText(_ text: String, color: Color, background: Color) -> some View {
        Text(text.isEmpty ? " " : text)
            .foregroundStyle(color)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
    }
}
