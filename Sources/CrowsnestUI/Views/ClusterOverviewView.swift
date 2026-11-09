import Charts
import CrowsnestKit
import SwiftUI

/// Cluster dashboard like Lens' "Cluster" page: capacity, usage, pod states, warnings.
struct ClusterOverviewView: View {
    @Environment(ClusterModel.self) private var model
    @State private var data: OverviewData?
    @State private var error: String?

    struct OverviewData {
        var nodes: [KubeObject]
        var pods: [KubeObject]
        var deployments: [KubeObject]
        var warnings: [KubeObject]
        var nodeMetrics: [String: ResourceUsage]?

        var cpuAllocatable: Double { nodes.reduce(0) { $0 + ($1["status.allocatable.cpu"]?.string.flatMap(Quantity.parse) ?? 0) } }
        var memoryAllocatable: Double { nodes.reduce(0) { $0 + ($1["status.allocatable.memory"]?.string.flatMap(Quantity.parse) ?? 0) } }
        var cpuUsage: Double? { nodeMetrics.map { $0.values.reduce(0) { $0 + $1.cpu } } }
        var memoryUsage: Double? { nodeMetrics.map { $0.values.reduce(0) { $0 + $1.memory } } }

        /// Sum of container requests of scheduled, non-terminated pods.
        func requests(_ resource: String) -> Double {
            pods.filter { !["Succeeded", "Failed"].contains($0["status.phase"]?.string ?? "") && $0["spec.nodeName"] != nil }
                .reduce(0) { sum, pod in
                    sum + (pod["spec.containers"]?.array ?? []).reduce(0) {
                        $0 + ($1.value(at: "resources.requests.\(resource)")?.string.flatMap(Quantity.parse) ?? 0)
                    }
                }
        }

        var podStates: [(state: String, count: Int, tone: StatusTone)] {
            var counts: [String: (Int, StatusTone)] = [:]
            for pod in pods {
                let s = PodStatus.status(of: pod)
                let key: String
                let tone: StatusTone
                switch s.tone {
                case .ok: key = "Running"; tone = .ok
                case .neutral: key = "Succeeded"; tone = .neutral
                case .progress: key = "Pending"; tone = .progress
                case .warning: key = "Warning"; tone = .warning
                case .error: key = "Failed"; tone = .error
                }
                counts[key, default: (0, tone)].0 += 1
            }
            return counts.map { ($0.key, $0.value.0, $0.value.1) }.sorted { $0.count > $1.count }
        }
    }

    var body: some View {
        ScrollView {
            if let data {
                VStack(alignment: .leading, spacing: 16) {
                    summaryCards(data)
                    HStack(alignment: .top, spacing: 16) {
                        capacityCard(data)
                        podChart(data)
                    }
                    if model.metrics.nodes != nil { historyCard(data) }
                    nodesCard(data)
                    warningsCard(data)
                }
                .padding(20)
            } else if let error {
                ContentUnavailableView("Overview not available", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView().padding(40)
            }
        }
        .navigationTitle("Cluster Overview")
        #if os(macOS)
        .navigationSubtitle(model.contextName ?? "")
        #endif
        .task(id: "\(model.contextName ?? "")|\(model.serverVersion ?? "")") {
            while !Task.isCancelled {
                await load()
                let interval = max(ClusterModel.refreshInterval, 10)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func historyCard(_ d: OverviewData) -> some View {
        let samples = model.metrics.clusterHistory()
        return Card(title: "Usage History") {
            HStack(alignment: .top, spacing: 24) {
                UsageChart(samples: samples, resource: .cpu, limit: d.cpuAllocatable, limitLabel: "allocatable")
                UsageChart(samples: samples, resource: .memory, limit: d.memoryAllocatable, limitLabel: "allocatable")
            }
            Text("Last \(Int(MetricsStore.window / 60)) minutes, sampled every \(Int(MetricsStore.interval.components.seconds)) s while Crowsnest is open.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func load() async {
        guard let client = model.client else { return }
        do {
            async let nodes = client.list(.nodes)
            async let pods = client.list(.pods)
            async let deployments = client.list(.deployments)
            async let events = client.list(.events, fieldSelector: "type=Warning")
            async let metrics = client.nodeMetrics()
            let warnings = try await events.sorted { (EventInfo.lastSeen($0) ?? .distantPast) > (EventInfo.lastSeen($1) ?? .distantPast) }
            data = OverviewData(nodes: try await nodes, pods: try await pods, deployments: try await deployments,
                                warnings: Array(warnings.prefix(50)), nodeMetrics: try? await metrics)
            error = nil
        } catch {
            if data == nil { self.error = error.localizedDescription }
        }
    }

    // MARK: Cards

    private func summaryCards(_ d: OverviewData) -> some View {
        let readyNodes = d.nodes.filter { NodeStatus.status(of: $0).tone == .ok }.count
        let runningPods = d.pods.filter { PodStatus.status(of: $0).tone == .ok }.count
        let readyDeployments = d.deployments.filter { ($0["status.readyReplicas"]?.int ?? 0) >= ($0["spec.replicas"]?.int ?? 0) }.count
        return HStack(spacing: 16) {
            StatCard(title: "Nodes", value: "\(readyNodes)/\(d.nodes.count)", subtitle: "ready",
                     tone: readyNodes == d.nodes.count ? .ok : .warning, symbol: "server.rack") {
                model.sidebarSelection = .kind(ResourceKind.nodes.id)
            }
            StatCard(title: "Pods", value: "\(runningPods)/\(d.pods.count)", subtitle: "running",
                     tone: d.podStates.contains { $0.tone == .error } ? .error : .ok, symbol: "shippingbox") {
                model.namespace = nil
                model.sidebarSelection = .kind(ResourceKind.pods.id)
            }
            StatCard(title: "Deployments", value: "\(readyDeployments)/\(d.deployments.count)", subtitle: "ready",
                     tone: readyDeployments == d.deployments.count ? .ok : .warning, symbol: "square.stack.3d.forward.dottedline") {
                model.namespace = nil
                model.sidebarSelection = .kind(ResourceKind.deployments.id)
            }
            StatCard(title: "Warnings", value: "\(d.warnings.count)", subtitle: "Events",
                     tone: d.warnings.isEmpty ? .ok : .warning, symbol: "exclamationmark.triangle") {
                model.sidebarSelection = .kind(ResourceKind.events.id)
            }
        }
    }

    private func capacityCard(_ d: OverviewData) -> some View {
        Card(title: "Capacity") {
            VStack(alignment: .leading, spacing: 16) {
                UsageBar(title: "CPU", used: d.cpuUsage ?? 0, requested: d.requests("cpu"),
                         capacity: d.cpuAllocatable, format: Quantity.formatCPU)
                UsageBar(title: "Memory", used: d.memoryUsage ?? 0, requested: d.requests("memory"),
                         capacity: d.memoryAllocatable, format: Quantity.formatBytes)
                if d.nodeMetrics == nil {
                    Label("metrics-server not installed – requests only", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func podChart(_ d: OverviewData) -> some View {
        Card(title: "Pods by Status") {
            HStack(spacing: 16) {
                Chart(d.podStates, id: \.state) { entry in
                    SectorMark(angle: .value("Count", entry.count), innerRadius: .ratio(0.6), angularInset: 1.5)
                        .foregroundStyle(entry.tone.color)
                }
                .frame(width: 120, height: 120)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(d.podStates, id: \.state) { entry in
                        HStack {
                            StatusDot(tone: entry.tone)
                            Text(entry.state)
                            Spacer()
                            Text("\(entry.count)").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: 360)
    }

    private func nodesCard(_ d: OverviewData) -> some View {
        Card(title: "Nodes") {
            VStack(spacing: 10) {
                ForEach(d.nodes) { node in
                    let status = NodeStatus.status(of: node)
                    let usage = d.nodeMetrics?[node.name]
                    let cpu = node["status.allocatable.cpu"]?.string.flatMap(Quantity.parse) ?? 0
                    let mem = node["status.allocatable.memory"]?.string.flatMap(Quantity.parse) ?? 0
                    HStack(spacing: 12) {
                        StatusDot(tone: status.tone)
                        Button(node.name) { model.reveal(kind: .nodes, name: node.name, namespace: nil) }
                            .linkButtonStyle()
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(width: 170, alignment: .leading)
                            .help(node.name)
                        Text(NodeStatus.roles(of: node)).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                        if let usage {
                            LabeledMiniBar(label: "CPU", fraction: cpu > 0 ? usage.cpu / cpu : 0)
                            LabeledMiniBar(label: "RAM", fraction: mem > 0 ? usage.memory / mem : 0)
                        } else {
                            Text(status.text).font(.caption)
                        }
                        Spacer()
                        Text(node["status.nodeInfo.kubeletVersion"]?.string ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func warningsCard(_ d: OverviewData) -> some View {
        Card(title: "Recent Warnings") {
            if d.warnings.isEmpty {
                Label("No warnings", systemImage: "checkmark.circle").foregroundStyle(.green)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(d.warnings.prefix(15)) { event in
                        HStack(alignment: .firstTextBaseline) {
                            Text(KubeDate.age(since: EventInfo.lastSeen(event)))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 50, alignment: .leading)
                            VStack(alignment: .leading, spacing: 1) {
                                Button("\(event["involvedObject.kind"]?.string ?? "")/\(event["involvedObject.name"]?.string ?? "") · \(event["reason"]?.string ?? "")") {
                                    model.reveal(kindName: event["involvedObject.kind"]?.string ?? "",
                                                 apiVersion: event["involvedObject.apiVersion"]?.string,
                                                 name: event["involvedObject.name"]?.string ?? "",
                                                 namespace: event["involvedObject.namespace"]?.string)
                                }
                                .linkButtonStyle()
                                Text(event["message"]?.string ?? "")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct Card<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.weight(.semibold))
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct StatCard: View {
    var title: String
    var value: String
    var subtitle: String
    var tone: StatusTone
    var symbol: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: symbol).foregroundStyle(tone.color)
                    Text(title).foregroundStyle(.secondary)
                }
                .font(.callout)
                Text(value).font(.system(size: 28, weight: .semibold).monospacedDigit())
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

struct LabeledMiniBar: View {
    var label: String
    var fraction: Double

    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(.secondary).fixedSize()
            ProgressView(value: min(max(fraction, 0), 1))
                .tint(fraction < 0.7 ? .green : (fraction < 0.9 ? .orange : .red))
                .frame(width: 80)
            Text("\(Int((fraction * 100).rounded()))%").font(.caption2.monospacedDigit()).lineLimit(1).frame(width: 40, alignment: .trailing)
        }
    }
}
