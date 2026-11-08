import CrowsnestKit
import SwiftUI

/// Sorts table rows by one dynamic column.
struct ColumnComparator: SortComparator {
    let column: ResourceColumn
    var order: SortOrder = .forward

    func compare(_ lhs: KubeObject, _ rhs: KubeObject) -> ComparisonResult {
        let result = CellValue.compare(column.value(lhs), column.value(rhs))
        guard order == .reverse else { return result }
        switch result {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.column.id == rhs.column.id && lhs.order == rhs.order }
    func hash(into hasher: inout Hasher) {
        hasher.combine(column.id)
        hasher.combine(order)
    }
}

struct ResourceListView: View {
    @Environment(ClusterModel.self) private var model
    let kind: ResourceKind
    @State private var sortOrder: [ColumnComparator] = []

    private var columns: [ResourceColumn] {
        var cols = kind.allColumns
        if !(kind.namespaced && model.namespace == nil) {
            cols.removeAll { $0.id == "Namespace" }
        }
        let usageColumns = self.usageColumns
        if !usageColumns.isEmpty {
            if kind == .nodes { cols.removeAll { $0.id == "CPU" || $0.id == "Memory" } }
            let insertAt = cols.firstIndex { $0.id == "Age" } ?? cols.endIndex
            cols.insert(contentsOf: usageColumns, at: insertAt)
        }
        return cols
    }

    /// CPU/memory columns from metrics-server, sortable by value.
    private var usageColumns: [ResourceColumn] {
        let store = model.metrics
        // Precompute per-object usage and reference (limit or allocatable), keyed by object id.
        var usage: [String: ResourceUsage] = [:]
        var reference: [String: ResourceSpec] = [:]
        switch kind {
        case .pods:
            guard let pods = store.pods else { return [] }
            for o in model.objects {
                usage[o.id] = pods["\(o.namespace ?? "")/\(o.name)"]?.total
                let spec = ResourceSpec.of(pod: o)
                reference[o.id] = ResourceSpec(cpuLimit: spec.cpuLimit, memoryLimit: spec.memoryLimit)
            }
        case .nodes:
            guard let nodes = store.nodes else { return [] }
            for o in model.objects {
                usage[o.id] = nodes[o.name]
                reference[o.id] = ResourceSpec(cpuLimit: o["status.allocatable.cpu"]?.string.flatMap(Quantity.parse),
                                               memoryLimit: o["status.allocatable.memory"]?.string.flatMap(Quantity.parse))
            }
        case .namespaces:
            guard let byNamespace = store.namespaceUsage else { return [] }
            for o in model.objects { usage[o.id] = byNamespace[o.name] ?? ResourceUsage() }
        case _ where ClusterModel.workloadKinds.contains(kind):
            guard store.pods != nil else { return [] }
            for o in model.objects { usage[o.id] = store.usage(ofPods: model.podKeys(of: o, in: model.workloadPods)) }
        default:
            return []
        }
        let usageByID = usage, referenceByID = reference
        return [UsageResource.cpu, .memory].map { resource in
            ResourceColumn(resource.title, id: "usage-\(resource.title)", width: .normal) { o in
                guard let u = usageByID[o.id] else { return .text("–") }
                let value = resource.value(u)
                let ref = referenceByID[o.id].flatMap { resource == .cpu ? $0.cpuLimit : $0.memoryLimit }
                let fraction = ref.flatMap { $0 > 0 ? value / $0 : nil }
                return .meter(value: value, fraction: fraction, text: resource.format(value))
            }
        }
    }

    private var rows: [KubeObject] {
        let filtered = model.filteredObjects
        guard let comparator = sortOrder.first else { return filtered }
        return filtered.sorted { comparator.compare($0, $1) == .orderedAscending }
    }

    var body: some View {
        @Bindable var model = model
        let now = model.lastRefresh ?? .now
        Table(of: KubeObject.self, selection: $model.selectedObjectID, sortOrder: $sortOrder) {
            TableColumnForEach(columns) { column in
                TableColumn(column.title, sortUsing: ColumnComparator(column: column)) { object in
                    CellView(value: column.value(object), now: now)
                        .help(column.value(object).display(now: now))
                }
                .width(min: column.width.min, ideal: column.width.ideal)
            }
        } rows: {
            ForEach(rows) { TableRow($0) }
        }
        .id(kind.id + (model.namespace == nil ? "*" : ""))
        .contextMenu(forSelectionType: KubeObject.ID.self) { ids in
            if let id = ids.first, let object = model.objects.first(where: { $0.id == id }) {
                ObjectActionsMenu(object: object)
            }
        }
        .overlay { overlay }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Name or label=value")
        .inspector(isPresented: Binding(
            get: { model.selectedObject != nil },
            set: { if !$0 { model.selectedObjectID = nil } }
        )) {
            Group {
                if let object = model.selectedObject {
                    ObjectDetailView(object: object, kind: kind)
                }
            }
            .inspectorColumnWidth(min: 380, ideal: 560, max: 1000)
        }
        .navigationTitle(kind.title)
        #if os(macOS)
        .navigationSubtitle(subtitle)
        #endif
        .task(id: model.reloadKey) {
            while !Task.isCancelled {
                await model.reload()
                let interval = ClusterModel.refreshInterval
                guard interval > 0 else { break }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private var subtitle: String {
        var parts = ["\(model.filteredObjects.count) objects"]
        if let date = model.lastRefresh { parts.append("updated \(date.formatted(date: .omitted, time: .standard))") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var overlay: some View {
        if let error = model.listError, model.objects.isEmpty {
            ContentUnavailableView {
                Label("Loading failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { Task { await model.reload() } }
            }
        } else if model.objects.isEmpty && model.isLoading {
            ProgressView()
        } else if model.objects.isEmpty && model.lastRefresh != nil {
            ContentUnavailableView("No \(kind.title)", systemImage: kind.symbol,
                                   description: Text(model.namespace.map { "in namespace \($0)" } ?? ""))
        } else if !model.searchText.isEmpty && model.filteredObjects.isEmpty {
            ContentUnavailableView.search(text: model.searchText)
        }
    }
}

extension ResourceColumn.Width {
    var min: CGFloat {
        switch self {
        case .narrow: 45
        case .normal: 70
        case .wide: 120
        }
    }

    var ideal: CGFloat {
        switch self {
        case .narrow: 70
        case .normal: 120
        case .wide: 280
        }
    }
}

/// Context menu / action menu for an object.
struct ObjectActionsMenu: View {
    @Environment(ClusterModel.self) private var model
    let object: KubeObject

    var body: some View {
        let kind = model.kind(for: object)
        if object.kind == "Pod" {
            ShellMenuItems(pod: object)
        }
        if object.kind == "Pod" || object.kind == "Service" {
            PortForwardMenuItems(object: object)
        }
        Button("Edit YAML", systemImage: "pencil") { model.openEditor(for: object) }
        if kind?.capabilities.contains(.scale) == true {
            Button("Scale…", systemImage: "arrow.up.arrow.down") { model.scaleTarget = object }
        }
        ForEach(model.availableActions(for: object), id: \.self) { action in
            switch action {
            case .restart:
                Button("Restart", systemImage: "arrow.triangle.2.circlepath") { model.pendingAction = .init(kind: .restart, object: object) }
            case .cordon:
                Button("Cordon", systemImage: "nosign") { model.pendingAction = .init(kind: .cordon, object: object) }
            case .uncordon:
                Button("Uncordon", systemImage: "checkmark.circle") { model.pendingAction = .init(kind: .uncordon, object: object) }
            case .trigger:
                Button("Run Now", systemImage: "play") { model.pendingAction = .init(kind: .trigger, object: object) }
            case .delete:
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) { model.pendingAction = .init(kind: .delete, object: object) }
            }
        }
        Divider()
        Button("Copy Name", systemImage: "doc.on.doc") { Pasteboard.copy(object.name) }
        Button("Copy YAML", systemImage: "doc.plaintext") {
            if let yaml = try? object.cleanedForDisplay.yamlString() { Pasteboard.copy(yaml) }
        }
    }
}
