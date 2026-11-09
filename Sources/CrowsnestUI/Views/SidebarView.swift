import CrowsnestKit
import SwiftUI

struct SidebarView: View {
    @Environment(ClusterModel.self) private var model
    @State private var expandedCRDGroups: Set<String> = []

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            contextHeader
            List(selection: $model.sidebarSelection) {
                Label("Cluster Overview", systemImage: "gauge.with.dots.needle.50percent")
                    .tag(SidebarItem.overview)

                ForEach(ResourceCategory.allCases) { category in
                    Section(category.rawValue) {
                        ForEach(ResourceKind.builtin.filter { $0.category == category }) { kind in
                            Label(kind.title, systemImage: kind.symbol).tag(SidebarItem.kind(kind.id))
                        }
                        if category == .network {
                            Label {
                                Text("Port Forwards")
                            } icon: {
                                Image(systemName: "arrow.left.arrow.right")
                            }
                            .badge(model.portForwards.count)
                            .tag(SidebarItem.portForwards)
                        }
                        if category == .customResources {
                            customResourceGroups
                        }
                    }
                }
                Section("Helm") {
                    Label("Charts", systemImage: "books.vertical")
                        .tag(SidebarItem.helmCharts)
                    Label("Releases", systemImage: "shippingbox")
                        .tag(SidebarItem.helmReleases)
                }
                ExtensionSidebarSections()
            }
            .listStyle(.sidebar)
        }
    }

    private var contextHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Menu {
                ForEach(model.kubeconfig?.contextNames ?? [], id: \.self) { name in
                    Button {
                        Task { await model.selectContext(name) }
                    } label: {
                        if name == model.contextName {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(name)
                        }
                    }
                }
                Divider()
                Button("Reload kubeconfig") { Task { await model.loadKubeconfig() } }
            } label: {
                HStack {
                    Image(systemName: "server.rack")
                    VStack(alignment: .leading, spacing: 0) {
                        Text(model.contextName ?? "No Context").font(.headline).lineLimit(1)
                        Text(statusLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .borderlessMenuStyle()
            .menuIndicator(.visible)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var statusLine: String {
        if model.connectionError != nil { return "Not connected" }
        if let v = model.serverVersion { return "Kubernetes \(v)" }
        return model.contextName == nil ? "" : "Connecting…"
    }

    @ViewBuilder
    private var customResourceGroups: some View {
        let groups = Dictionary(grouping: model.customKinds, by: \.group)
        ForEach(groups.keys.sorted(), id: \.self) { group in
            DisclosureGroup(isExpanded: Binding(
                get: { expandedCRDGroups.contains(group) },
                set: { if $0 { expandedCRDGroups.insert(group) } else { expandedCRDGroups.remove(group) } }
            )) {
                ForEach(groups[group] ?? []) { kind in
                    Label(kind.title, systemImage: kind.symbol).tag(SidebarItem.kind(kind.id))
                }
            } label: {
                Label(group, systemImage: "folder").lineLimit(1)
            }
        }
    }
}
