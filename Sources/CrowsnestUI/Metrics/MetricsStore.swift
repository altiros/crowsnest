import CrowsnestKit
import Foundation
import Observation

/// One measurement of CPU (cores) and memory (bytes).
public struct UsageSample: Sendable, Identifiable, Equatable {
    public var date: Date
    public var cpu: Double
    public var memory: Double
    public var id: Date { date }
}

/// Polls metrics-server for the whole cluster and keeps a short history in memory, so lists,
/// details and charts can show usage without Prometheus. History only covers the time Crowsnest is open.
@MainActor @Observable
public final class MetricsStore {
    /// metrics-server's default resolution.
    public static let interval: Duration = .seconds(15)
    /// How much history to keep.
    public static let window: TimeInterval = 30 * 60

    /// Latest usage per pod ("namespace/name"); `nil` until loaded or if metrics-server is missing.
    public private(set) var pods: [String: PodUsage]?
    /// Latest usage per node.
    public private(set) var nodes: [String: ResourceUsage]?
    /// `false` once the cluster answered that metrics.k8s.io isn't available.
    public private(set) var isAvailable: Bool?
    public private(set) var lastUpdate: Date?

    @ObservationIgnored private var podHistory: [String: [UsageSample]] = [:]
    @ObservationIgnored private var nodeHistory: [String: [UsageSample]] = [:]
    /// Bumped on every sample so views depending on history refresh.
    public private(set) var revision = 0

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var client: KubeClient?

    public init() {}

    /// Starts sampling for a client (stops the previous one and clears all data).
    func start(client: KubeClient) {
        stop()
        self.client = client
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sample()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        client = nil
        pods = nil
        nodes = nil
        isAvailable = nil
        lastUpdate = nil
        podHistory = [:]
        nodeHistory = [:]
        revision += 1
    }

    /// Takes a sample right away (e.g. on manual refresh).
    func sampleNow() {
        Task { await sample() }
    }

    private func sample() async {
        guard let client else { return }
        async let podResult = try? client.podMetrics(namespace: nil)
        async let nodeResult = try? client.nodeMetrics()
        let (podMetrics, nodeMetrics) = await (podResult, nodeResult)
        guard client === self.client else { return }

        // `try?` flattens "not installed" (nil) and errors; treat both as unavailable for now.
        let newPods = podMetrics ?? nil
        let newNodes = nodeMetrics ?? nil
        isAvailable = newPods != nil || newNodes != nil
        let now = Date.now
        if let newPods {
            pods = newPods
            for (key, usage) in newPods { append(UsageSample(date: now, cpu: usage.total.cpu, memory: usage.total.memory), to: &podHistory, key: key) }
            podHistory = podHistory.filter { newPods[$0.key] != nil || ($0.value.last?.date ?? .distantPast) > now - Self.window }
        }
        if let newNodes {
            nodes = newNodes
            for (key, usage) in newNodes { append(UsageSample(date: now, cpu: usage.cpu, memory: usage.memory), to: &nodeHistory, key: key) }
        }
        lastUpdate = now
        revision += 1
    }

    private func append(_ sample: UsageSample, to history: inout [String: [UsageSample]], key: String) {
        var samples = history[key] ?? []
        samples.append(sample)
        let cutoff = sample.date - Self.window
        if let first = samples.firstIndex(where: { $0.date >= cutoff }), first > 0 { samples.removeFirst(first) }
        history[key] = samples
    }

    // MARK: - Queries

    public func pod(_ namespace: String?, _ name: String) -> PodUsage? {
        pods?["\(namespace ?? "")/\(name)"]
    }

    public func history(pod name: String, namespace: String?) -> [UsageSample] {
        _ = revision
        return podHistory["\(namespace ?? "")/\(name)"] ?? []
    }

    public func history(node name: String) -> [UsageSample] {
        _ = revision
        return nodeHistory[name] ?? []
    }

    /// Summed history of several pods (samples of one round share the same date).
    public func history(pods keys: [String]) -> [UsageSample] {
        _ = revision
        return Self.sum(keys.compactMap { podHistory[$0] })
    }

    /// Summed history of all nodes.
    public func clusterHistory() -> [UsageSample] {
        _ = revision
        return Self.sum(Array(nodeHistory.values))
    }

    /// Current usage summed over pods.
    public func usage(ofPods keys: [String]) -> ResourceUsage? {
        guard let pods else { return nil }
        return keys.reduce(into: ResourceUsage()) { sum, key in
            if let u = pods[key]?.total { sum.cpu += u.cpu; sum.memory += u.memory }
        }
    }

    /// Current usage per namespace.
    public var namespaceUsage: [String: ResourceUsage]? {
        guard let pods else { return nil }
        var result: [String: ResourceUsage] = [:]
        for (key, usage) in pods {
            let ns = String(key.split(separator: "/", maxSplits: 1).first ?? "")
            result[ns, default: ResourceUsage()].cpu += usage.total.cpu
            result[ns, default: ResourceUsage()].memory += usage.total.memory
        }
        return result
    }

    static func sum(_ series: [[UsageSample]]) -> [UsageSample] {
        var byDate: [Date: UsageSample] = [:]
        for samples in series {
            for s in samples {
                var total = byDate[s.date] ?? UsageSample(date: s.date, cpu: 0, memory: 0)
                total.cpu += s.cpu
                total.memory += s.memory
                byDate[s.date] = total
            }
        }
        return byDate.values.sorted { $0.date < $1.date }
    }
}
