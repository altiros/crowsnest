import CrowsnestKit
import SwiftUI

/// Detail panel for one object, like Lens' slide-in details.
struct ObjectDetailView: View {
    @Environment(ClusterModel.self) private var model
    let object: KubeObject
    let kind: ResourceKind

    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case yaml = "YAML"
        case logs = "Logs"
        case events = "Events"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .overview

    private var tabs: [Tab] {
        var result: [Tab] = [.overview, .yaml]
        if kind == .pods { result.append(.logs) }
        if kind != .events { result.append(.events) }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("View", selection: $tab) {
                ForEach(tabs) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            Divider()
            switch tab {
            case .overview: ObjectOverviewView(object: object, kind: kind)
            case .yaml: YAMLTabView(object: object, kind: kind)
            case .logs: LogsView(pod: object)
            case .events: ObjectEventsView(object: object)
            }
        }
        .id(object.id)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: kind.symbol)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(object.name)
                    .font(.headline)
                    .textSelection(.enabled)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(kind.kind)
                    if let ns = object.namespace { Text("·"); Text(ns) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                ObjectActionsMenu(object: object)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .borderlessMenuStyle()
            .fixedSize()
            Button {
                model.selectedObjectID = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .help("Close")
        }
        .padding(12)
    }
}

// MARK: - YAML

struct YAMLTabView: View {
    @Environment(ClusterModel.self) private var model
    let object: KubeObject
    let kind: ResourceKind
    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") { Pasteboard.copy(text) }
                Button("Edit in Editor", systemImage: "pencil") { model.openEditor(for: object) }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
            .padding(8)
            YAMLEditorView(text: $text, isEditable: false)
        }
        .onAppear(perform: render)
        .onChange(of: object.resourceVersion) { render() }
    }

    private func render() {
        text = (try? object.cleanedForDisplay.yamlString()) ?? "# Could not render YAML"
    }
}

// MARK: - Events

struct ObjectEventsView: View {
    @Environment(ClusterModel.self) private var model
    let object: KubeObject
    @State private var events: [KubeObject]?
    @State private var error: String?

    var body: some View {
        Group {
            if let events, events.isEmpty {
                ContentUnavailableView("No Events", systemImage: "bell.slash")
            } else if let events {
                List(events) { event in
                    EventRow(event: event)
                }
            } else if let error {
                ContentUnavailableView("Error", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: object.resourceVersion) {
            guard let client = model.client else { return }
            do {
                events = try await client.events(for: object)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct EventRow: View {
    let event: KubeObject

    var body: some View {
        let isWarning = event["type"]?.string == "Warning"
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                StatusDot(tone: isWarning ? .warning : .neutral)
                Text(event["reason"]?.string ?? "").font(.headline)
                Spacer()
                let count = event["count"]?.int ?? event["series.count"]?.int ?? 1
                if count > 1 { Text("×\(count)").font(.caption).foregroundStyle(.secondary) }
                Text(KubeDate.age(since: EventInfo.lastSeen(event))).font(.caption).foregroundStyle(.secondary)
            }
            Text(event["message"]?.string ?? "")
                .font(.callout)
                .textSelection(.enabled)
            if let source = event["source.component"]?.string ?? event["reportingComponent"]?.string, !source.isEmpty {
                Text(source).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}
