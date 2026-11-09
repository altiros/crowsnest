import CrowsnestKit
import SwiftUI

/// Main window: sidebar with resource categories, list/overview, detail inspector.
public struct RootView: View {
    @State private var model = ClusterModel()
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var showSettings = false
    @AppStorage(SettingsKey.appearance) private var appearance = "system"

    public init() {}

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
                #if !os(macOS)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Settings", systemImage: "gearshape") { showSettings = true }
                    }
                }
                #endif
        } detail: {
            #if os(macOS)
            VSplitView {
                bannerAndContent.modifier(ContentSearch()).frame(minHeight: 220)
                if model.isEditorVisible {
                    EditorDock().frame(minHeight: 280, idealHeight: 380)
                }
            }
            // Attached once to the detail column: per-branch `.toolbar` modifiers on the
            // switching content left stale copies behind on macOS (duplicate New/Dock/Refresh).
            .toolbar { MainToolbar() }
            #else
            VStack(spacing: 0) {
                bannerAndContent.modifier(ContentSearch())
                if model.isEditorVisible {
                    Divider()
                    EditorDock().frame(height: 360)
                }
            }
            .toolbar { MainToolbar() }
            #endif
        }
        .environment(model)
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        .task { await model.loadKubeconfig() }
        .confirmationDialog(
            model.pendingAction?.title ?? "",
            isPresented: Binding(get: { model.pendingAction != nil }, set: { if !$0 { model.pendingAction = nil } }),
            titleVisibility: .visible,
            presenting: model.pendingAction
        ) { action in
            Button(action.confirmLabel, role: action.isDestructive ? .destructive : nil) {
                Task { await model.perform(action) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete \(model.pendingBulkDelete?.count ?? 0) objects?",
            isPresented: Binding(get: { model.pendingBulkDelete != nil }, set: { if !$0 { model.pendingBulkDelete = nil } }),
            titleVisibility: .visible,
            presenting: model.pendingBulkDelete
        ) { targets in
            Button("Delete \(targets.count) Objects", role: .destructive) {
                Task { await model.delete(targets) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { targets in
            let names = targets.prefix(12).map { o in o.namespace.map { "\($0)/\(o.name)" } ?? o.name }
            Text(names.joined(separator: "\n") + (targets.count > 12 ? "\n… and \(targets.count - 12) more" : ""))
        }
        .confirmationDialog(
            "Discard unsaved changes in \"\(model.tabPendingClose?.title ?? "")\"?",
            isPresented: Binding(get: { model.tabPendingClose != nil }, set: { if !$0 { model.tabPendingClose = nil } }),
            titleVisibility: .visible,
            presenting: model.tabPendingClose
        ) { tab in
            Button("Discard", role: .destructive) { model.closeEditorTab(tab, force: true) }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $model.scaleTarget) { object in
            ScaleSheet(object: object)
                .environment(model)
        }
        .sheet(item: $model.portForwardRequest) { request in
            PortForwardSheet(request: request)
                .environment(model)
        }
        .alert(
            "Error",
            isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(model.alertMessage ?? "")
        }
        .toastOverlay($model.toast)
        #if !os(macOS)
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
                    .navigationTitle("Settings")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } }
                    }
            }
            .environment(model)
        }
        #endif
    }

    private var bannerAndContent: some View {
        VStack(spacing: 0) {
            if model.isDemo {
                DemoBanner()
                Divider()
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.configError {
            ContentUnavailableView {
                Label("No kubeconfig", systemImage: "doc.badge.gearshape")
            } description: {
                #if os(macOS)
                Text(error)
                #else
                Text(error + "\nImport a kubeconfig with embedded certificates, e.g. created with \"kubectl config view --raw --flatten --minify\".")
                #endif
            } actions: {
                #if os(macOS)
                Button("Reload") { Task { await model.loadKubeconfig() } }
                #else
                KubeconfigImportButtons()
                #endif
                Button("Try the Demo Cluster", systemImage: "play.circle") { Task { await model.openDemo() } }
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
            }
        } else if model.kubeconfig == nil {
            ProgressView()
        } else if let error = model.connectionError {
            ContentUnavailableView {
                Label("Connection failed", systemImage: "bolt.horizontal.circle")
            } description: {
                Text(error)
            } actions: {
                Button("Reconnect") {
                    Task { if let name = model.contextName { await model.selectContext(name, force: true) } }
                }
            }
        } else if case .extensionPage(let id) = model.sidebarSelection {
            if let page = Extensions.page(id: id) {
                page.content(model)
            } else {
                // Saved selection from a build with extensions, opened in the open-source build.
                ContentUnavailableView("Not available in this build", systemImage: "puzzlepiece.extension")
            }
        } else if model.sidebarSelection == .helmCharts {
            HelmChartsView()
        } else if model.sidebarSelection == .helmReleases {
            HelmReleasesView()
        } else if model.sidebarSelection == .portForwards {
            PortForwardListView()
        } else if model.sidebarSelection == .overview || model.sidebarSelection == nil {
            ClusterOverviewView()
        } else if let kind = model.selectedKind {
            ResourceListView(kind: kind)
        } else {
            ContentUnavailableView("Resource not available", systemImage: "questionmark.folder")
        }
    }
}

/// The one search field of the detail column. Pages must not add their own `.searchable`: when two toolbar search
/// fields swap during a page change (e.g. Helm Releases ↔ Pods), AppKit's NSToolbar throws and the app crashes.
/// Here the field stays in place across searchable pages and only its prompt changes.
struct ContentSearch: ViewModifier {
    @Environment(ClusterModel.self) private var model

    private var prompt: String? {
        guard model.configError == nil, model.kubeconfig != nil, model.connectionError == nil else { return nil }
        switch model.sidebarSelection {
        case .helmReleases: return "Release or chart"
        case .helmCharts: return "Chart, keyword or repository"
        case .kind: return model.selectedKind != nil ? "Name or label=value" : nil
        default: return nil
        }
    }

    func body(content: Content) -> some View {
        @Bindable var model = model
        if let prompt {
            content.searchable(text: $model.searchText, placement: .toolbar, prompt: Text(prompt))
        } else {
            content
        }
    }
}

struct MainToolbar: ToolbarContent {
    @Environment(ClusterModel.self) private var model

    var body: some ToolbarContent {
        // No cluster actions until a kubeconfig is loaded.
        if model.configError == nil && model.kubeconfig != nil {
            items
        }
    }

    @ToolbarContentBuilder
    private var items: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            NewResourceMenu(label: "New")
            Button {
                if model.editorTabs.isEmpty && model.terminals.isEmpty && !model.isEditorVisible {
                    model.newResourceTab()
                } else {
                    model.isEditorVisible.toggle()
                }
            } label: {
                Label("Dock", systemImage: "rectangle.bottomthird.inset.filled")
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .help("Show/hide editor and terminals (⇧⌘E)")
            // Only lists of namespaced kinds can be filtered; the overview is always cluster-wide.
            // Charts: the namespace goes into the install command.
            if model.selectedKind?.namespaced == true || model.sidebarSelection == .helmReleases || model.sidebarSelection == .helmCharts {
                namespacePicker
            }
            Button {
                model.metrics.sampleNow()
                Task {
                    await model.refreshNamespaces()
                    switch model.sidebarSelection {
                    case .helmReleases: await model.loadHelm()
                    case .helmCharts: await HelmCatalog.shared.refresh()
                    default: await model.reload()
                    }
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .help("Refresh (⌘R)")
        }
    }

    private var namespacePicker: some View {
        Menu {
            Button("All Namespaces") { model.namespace = nil }
            Divider()
            ForEach(model.namespaces, id: \.self) { ns in
                Button(ns) { model.namespace = ns }
            }
        } label: {
            Label(model.namespace ?? "All Namespaces", systemImage: "square.stack.3d.up")
                .labelStyle(.titleAndIcon)
        }
        .help("Namespace")
    }
}

struct ScaleSheet: View {
    @Environment(ClusterModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let object: KubeObject
    @State private var replicas = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Scale \(object.kind) \"\(object.name)\"").font(.headline)
            Stepper(value: $replicas, in: 0...500) {
                HStack {
                    Text("Replicas:")
                    TextField("Replicas", value: $replicas, format: .number)
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Scale") {
                    Task {
                        await model.scale(object, to: replicas)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 340)
        .onAppear { replicas = object["spec.replicas"]?.int ?? 1 }
    }
}

/// Shown above the content while the simulated demo cluster is selected.
struct DemoBanner: View {
    @Environment(ClusterModel.self) private var model
    @State private var showImport = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Demo Cluster").font(.callout.weight(.semibold))
                Text("Simulated cluster – try anything: scale, restart, delete, edit YAML. Changes are kept until the app quits.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            #if os(macOS)
            Text("Switch to your clusters in the sidebar.").font(.caption).foregroundStyle(.secondary)
            #else
            Button("Connect Your Cluster…") { showImport = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
            #endif
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.tint.opacity(0.08))
        #if !os(macOS)
        .sheet(isPresented: $showImport) {
            NavigationStack {
                VStack(spacing: 16) {
                    Text("Import a kubeconfig with embedded certificates or tokens, e.g. created with \"kubectl config view --raw --flatten --minify\". Exec auth plugins (EKS, GKE, AKS logins) are not available on iPad.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    KubeconfigImportButtons()
                    Spacer()
                }
                .padding(24)
                .navigationTitle("Connect Your Cluster")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { showImport = false } } }
            }
            .environment(model)
            .onChange(of: model.contextName) { if !model.isDemo { showImport = false } }
        }
        #endif
    }
}
