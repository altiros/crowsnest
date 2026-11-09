import Foundation
import CrowsnestKit
import Observation

/// Sidebar entries.
public enum SidebarItem: Hashable, Sendable {
    case overview
    case portForwards
    case helmReleases
    /// A page contributed by an extension (see `Extensions`).
    case extensionPage(String)
    case kind(String)

    var storageKey: String {
        switch self {
        case .overview: "overview"
        case .portForwards: "portForwards"
        case .helmReleases: "helmReleases"
        case .extensionPage(let id): "ext:\(id)"
        case .kind(let id): "kind:\(id)"
        }
    }

    init(storageKey: String) {
        if storageKey.hasPrefix("kind:") {
            self = .kind(String(storageKey.dropFirst(5)))
        } else if storageKey.hasPrefix("ext:") {
            self = .extensionPage(String(storageKey.dropFirst(4)))
        } else {
            switch storageKey {
            case "portForwards": self = .portForwards
            case "helmReleases": self = .helmReleases
            default: self = .overview
            }
        }
    }
}

/// Settings keys shared by the app and the model.
public enum SettingsKey {
    public static let kubeconfigPath = "kubeconfigPath"
    public static let refreshInterval = "refreshInterval"
    public static let lastContext = "lastContext"
    public static let lastSidebarItem = "lastSidebarItem"
    /// "system", "light" or "dark".
    public static let appearance = "appearance"
}

/// State of one window: the selected cluster context, namespace, resource kind and objects.
@MainActor @Observable
public final class ClusterModel {
    // Kubeconfig
    public private(set) var kubeconfig: KubeConfig?
    public private(set) var configError: String?

    // Connection
    public private(set) var contextName: String?
    public private(set) var client: KubeClient?
    public private(set) var connectionError: String?
    public private(set) var serverVersion: String?
    public private(set) var namespaces: [String] = []
    public private(set) var customKinds: [ResourceKind] = []

    // Browsing
    public var namespace: String? {
        didSet { if namespace != oldValue { objects = []; selectedObjectID = nil } }
    }
    public var sidebarSelection: SidebarItem? = .overview {
        didSet {
            guard sidebarSelection != oldValue else { return }
            objects = []
            listError = nil
            selectedObjectID = nil
            searchText = ""
            UserDefaults.standard.set(sidebarSelection?.storageKey, forKey: SettingsKey.lastSidebarItem)
        }
    }
    public private(set) var objects: [KubeObject] = []
    public private(set) var listError: String?
    public private(set) var isLoading = false
    public internal(set) var lastRefresh: Date?
    /// Selected rows of the resource list (multiple selection).
    public var selectedObjectIDs: Set<KubeObject.ID> = []
    /// The selected object's id when exactly one row is selected (drives the detail inspector).
    public var selectedObjectID: KubeObject.ID? {
        get { selectedObjectIDs.count == 1 ? selectedObjectIDs.first : nil }
        set { selectedObjectIDs = newValue.map { [$0] } ?? [] }
    }
    public var searchText = ""
    /// Pods in the listed namespace, for usage of workloads (only loaded for workload kinds).
    public private(set) var workloadPods: [KubeObject] = []
    /// metrics-server data and history for the current context.
    public let metrics = MetricsStore()

    // Actions & feedback
    public var pendingAction: PendingAction?
    /// Objects waiting for confirmation of a bulk delete.
    public var pendingBulkDelete: [KubeObject]?
    public var scaleTarget: KubeObject?
    public var alertMessage: String?
    public var toast: String?

    // Dock (editor and terminal tabs)
    public var editorTabs: [EditorTab] = []
    public var terminals: [TerminalSession] = []
    public var activeDockTabID: UUID?
    public var isEditorVisible = false
    public var tabPendingClose: EditorTab?
    public private(set) var contextDefaultNamespace: String?

    // Port forwarding
    public var portForwards: [PortForwardEntry] = []
    public var portForwardRequest: PortForwardRequest?

    // Helm (read-only)
    /// All revisions of all releases in the current namespace scope.
    public internal(set) var helmRevisions: [HelmRelease] = []
    public internal(set) var helmError: String?
    public var selectedHelmReleaseKey: String?

    private var pendingReveal: (kindID: String, namespace: String?, name: String)?
    private var loadGeneration = 0

    public init() {
        if let stored = UserDefaults.standard.string(forKey: SettingsKey.lastSidebarItem) {
            sidebarSelection = SidebarItem(storageKey: stored)
        }
    }

    // MARK: - Derived

    public var allKinds: [ResourceKind] { ResourceKind.builtin + customKinds }

    public var selectedKind: ResourceKind? {
        guard case .kind(let id) = sidebarSelection else { return nil }
        return allKinds.first { $0.id == id }
    }

    public var selectedObject: KubeObject? {
        guard let id = selectedObjectID else { return nil }
        return objects.first { $0.id == id }
    }

    public var filteredObjects: [KubeObject] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return objects }
        if query.contains("=") {
            let parts = query.split(separator: "=", maxSplits: 1).map(String.init)
            return objects.filter { o in o.labels.contains { $0.key.lowercased() == parts[0] && $0.value.lowercased() == (parts.count > 1 ? parts[1] : "") } }
        }
        return objects.filter { $0.name.lowercased().contains(query) || ($0.namespace?.lowercased().contains(query) ?? false) }
    }

    /// Changes whenever the list must be reloaded from scratch.
    public var reloadKey: String {
        "\(contextName ?? "")|\(namespace ?? "*")|\(String(describing: sidebarSelection))"
    }

    public static var refreshInterval: Double {
        let v = UserDefaults.standard.double(forKey: SettingsKey.refreshInterval)
        return v == 0 && UserDefaults.standard.object(forKey: SettingsKey.refreshInterval) == nil ? 5 : v
    }

    // MARK: - Kubeconfig & context

    public func loadKubeconfig() async {
        #if os(macOS)
        let custom = UserDefaults.standard.string(forKey: SettingsKey.kubeconfigPath) ?? ""
        let urls = custom.isEmpty
            ? KubeConfig.defaultFileURLs()
            : custom.split(separator: ":").map { URL(fileURLWithPath: NSString(string: String($0)).expandingTildeInPath) }
        #else
        // iPadOS: only kubeconfigs imported into the app container.
        let urls = KubeconfigStore.files()
        guard !urls.isEmpty else {
            kubeconfig = nil
            configError = "No kubeconfig imported yet."
            return
        }
        #endif
        do {
            let config = try KubeConfig.load(from: urls)
            kubeconfig = config
            configError = nil
            let remembered = UserDefaults.standard.string(forKey: SettingsKey.lastContext)
            let preferred = [contextName, remembered, config.currentContext, config.contextNames.first]
                .compactMap { $0 }
                .first { config.contextNames.contains($0) }
            if let preferred {
                await selectContext(preferred, force: true)
            }
        } catch {
            kubeconfig = nil
            configError = error.localizedDescription
        }
    }

    public func selectContext(_ name: String, force: Bool = false) async {
        guard force || name != contextName, let kubeconfig else { return }
        contextName = name
        UserDefaults.standard.set(name, forKey: SettingsKey.lastContext)
        client = nil
        metrics.stop()
        serverVersion = nil
        connectionError = nil
        namespaces = []
        customKinds = []
        objects = []
        selectedObjectID = nil
        do {
            let connection = try kubeconfig.connection(forContext: name)
            namespace = connection.defaultNamespace
            contextDefaultNamespace = connection.defaultNamespace
            let client = try await KubeClientPool.shared.client(for: connection)
            guard contextName == name else { return }
            self.client = client
            metrics.start(client: client)
            async let version = client.serverVersion()
            async let names = client.namespaceNames()
            async let crds = client.customResourceKinds()
            serverVersion = try await version.gitVersion
            namespaces = (try? await names) ?? connection.defaultNamespace.map { [$0] } ?? []
            customKinds = (try? await crds) ?? []
        } catch {
            if contextName == name { connectionError = error.localizedDescription }
        }
    }

    // MARK: - Loading

    /// Reloads the current list. Called periodically by the list view.
    public func reload() async {
        guard let client, let kind = selectedKind else { return }
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            let ns = kind.namespaced ? namespace : nil
            let items = try await client.list(kind, namespace: ns)
            var pods: [KubeObject] = []
            if Self.workloadKinds.contains(kind) { pods = (try? await client.list(.pods, namespace: ns)) ?? [] }
            guard generation == loadGeneration, selectedKind == kind else { return }
            objects = items
            workloadPods = pods
            listError = nil
            lastRefresh = .now
            syncEditorTabs(with: kind, objects: items)
            if let reveal = pendingReveal, reveal.kindID == kind.id,
               let match = items.first(where: { $0.name == reveal.name && $0.namespace == reveal.namespace }) {
                selectedObjectID = match.id
                pendingReveal = nil
            }
        } catch {
            guard generation == loadGeneration else { return }
            listError = error.localizedDescription
        }
    }

    /// Kinds whose list shows the summed usage of their pods.
    static let workloadKinds: [ResourceKind] = [.deployments, .statefulSets, .daemonSets, .replicaSets, .jobs]

    /// Keys ("namespace/name") of the pods selected by a workload.
    func podKeys(of workload: KubeObject, in pods: [KubeObject]) -> [String] {
        let selector = workload["spec.selector"]
        return pods.filter { $0.namespace == workload.namespace && LabelSelector.matches(selector, labels: $0.labels) }
            .map { "\($0.namespace ?? "")/\($0.name)" }
    }

    public func refreshNamespaces() async {
        guard let client else { return }
        if let names = try? await client.namespaceNames() { namespaces = names }
    }

    /// Navigates to an object (e.g. from an owner reference or a related pod).
    public func reveal(kind: ResourceKind, name: String, namespace: String?) {
        pendingReveal = (kind.id, namespace, name)
        sidebarSelection = .kind(kind.id)
        if kind.namespaced, let current = self.namespace, current != namespace {
            self.namespace = nil
        }
        Task { await reload() }
    }

    public func reveal(kindName: String, apiVersion: String? = nil, name: String, namespace: String?) {
        let group = apiVersion.map { $0.contains("/") ? String($0.split(separator: "/")[0]) : "" }
        let kind = allKinds.first { $0.kind == kindName && (group == nil || $0.group == group) }
            ?? allKinds.first { $0.kind == kindName }
        guard let kind else {
            toast = "\(kindName) is not shown"
            return
        }
        reveal(kind: kind, name: name, namespace: kind.namespaced ? namespace : nil)
    }

    public func kind(for object: KubeObject) -> ResourceKind? {
        let group = object.apiVersion.contains("/") ? String(object.apiVersion.split(separator: "/")[0]) : ""
        return allKinds.first { $0.kind == object.kind && $0.group == group } ?? selectedKind
    }

    // MARK: - Actions

    public struct PendingAction: Identifiable, Sendable {
        public enum Kind: Sendable { case delete, restart, cordon, uncordon, trigger }
        public var kind: Kind
        public var object: KubeObject
        public var id: String { "\(kind)-\(object.id)" }

        public var title: String {
            switch kind {
            case .delete: "Delete \(object.kind) \"\(object.name)\"?"
            case .restart: "Restart \(object.kind) \"\(object.name)\"?"
            case .cordon: "Cordon node \"\(object.name)\"?"
            case .uncordon: "Uncordon node \"\(object.name)\"?"
            case .trigger: "Run CronJob \"\(object.name)\" now?"
            }
        }

        public var confirmLabel: String {
            switch kind {
            case .delete: "Delete"
            case .restart: "Restart"
            case .cordon: "Cordon"
            case .uncordon: "Uncordon"
            case .trigger: "Run"
            }
        }

        public var isDestructive: Bool { kind == .delete || kind == .cordon }
    }

    public func perform(_ action: PendingAction) async {
        guard let client, let kind = kind(for: action.object) else { return }
        let o = action.object
        do {
            switch action.kind {
            case .delete:
                try await client.delete(kind, name: o.name, namespace: o.namespace)
                if selectedObjectID == o.id { selectedObjectID = nil }
                toast = "Deleting \(o.name)"
            case .restart:
                try await client.restart(kind, name: o.name, namespace: o.namespace)
                toast = "Restart of \(o.name) triggered"
            case .cordon, .uncordon:
                try await client.setUnschedulable(node: o.name, action.kind == .cordon)
                toast = action.kind == .cordon ? "\(o.name) cordoned" : "\(o.name) uncordoned"
            case .trigger:
                let job = try await client.trigger(cronJob: o)
                toast = "Job \(job.name) created"
            }
            await reload()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// Selected objects that can be deleted (nodes never are).
    public var deletableSelection: [KubeObject] {
        objects.filter { selectedObjectIDs.contains($0.id) && availableActions(for: $0).contains(.delete) }
    }

    /// Deletes several objects; reports failures in one alert.
    public func delete(_ targets: [KubeObject]) async {
        guard let client else { return }
        var failures: [String] = []
        for object in targets {
            guard let kind = kind(for: object) else { continue }
            do {
                try await client.delete(kind, name: object.name, namespace: object.namespace)
                selectedObjectIDs.remove(object.id)
            } catch {
                failures.append("\(object.name): \(error.localizedDescription)")
            }
        }
        let deleted = targets.count - failures.count
        if deleted > 0 { toast = deleted == 1 ? "Deleting \(targets[0].name)" : "Deleting \(deleted) objects" }
        if !failures.isEmpty {
            alertMessage = "\(failures.count) of \(targets.count) objects could not be deleted:\n" + failures.joined(separator: "\n")
        }
        await reload()
    }

    public func scale(_ object: KubeObject, to replicas: Int) async {
        guard let client, let kind = kind(for: object) else { return }
        do {
            try await client.scale(kind, name: object.name, namespace: object.namespace, replicas: replicas)
            toast = "\(object.name) scaled to \(replicas)"
            await reload()
        } catch {
            alertMessage = error.localizedDescription
        }
    }


    public func availableActions(for object: KubeObject) -> [PendingAction.Kind] {
        guard let kind = kind(for: object) else { return [.delete] }
        var result: [PendingAction.Kind] = []
        if kind.capabilities.contains(.restart) { result.append(.restart) }
        if kind == .nodes { result.append(object["spec.unschedulable"]?.bool == true ? .uncordon : .cordon) }
        if kind == .cronJobs { result.append(.trigger) }
        if kind != .nodes { result.append(.delete) }
        return result
    }
}
