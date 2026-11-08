import Foundation

/// Usage of one pod from metrics-server, in total and per container.
public struct PodUsage: Sendable, Equatable {
    public var total = ResourceUsage()
    public var containers: [String: ResourceUsage] = [:]

    public init(total: ResourceUsage = ResourceUsage(), containers: [String: ResourceUsage] = [:]) {
        self.total = total
        self.containers = containers
    }
}

/// Requests and limits declared in pod specs. `nil` means "not set".
public struct ResourceSpec: Sendable, Equatable {
    public var cpuRequest: Double?
    public var memoryRequest: Double?
    public var cpuLimit: Double?
    public var memoryLimit: Double?

    public init(cpuRequest: Double? = nil, memoryRequest: Double? = nil, cpuLimit: Double? = nil, memoryLimit: Double? = nil) {
        self.cpuRequest = cpuRequest
        self.memoryRequest = memoryRequest
        self.cpuLimit = cpuLimit
        self.memoryLimit = memoryLimit
    }

    /// Requests and limits of one container spec.
    public static func of(container: JSONValue) -> ResourceSpec {
        func q(_ path: String) -> Double? { container.value(at: path)?.string.flatMap(Quantity.parse) }
        return ResourceSpec(cpuRequest: q("resources.requests.cpu"), memoryRequest: q("resources.requests.memory"),
                            cpuLimit: q("resources.limits.cpu"), memoryLimit: q("resources.limits.memory"))
    }

    /// Sum over the pod's (non-init) containers. A limit is only known if every container sets it.
    public static func of(pod: KubeObject) -> ResourceSpec {
        let specs = (pod["spec.containers"]?.array ?? []).map(of(container:))
        guard !specs.isEmpty else { return ResourceSpec() }
        func sum(_ key: KeyPath<ResourceSpec, Double?>, requireAll: Bool) -> Double? {
            let values = specs.compactMap { $0[keyPath: key] }
            if values.isEmpty || (requireAll && values.count != specs.count) { return nil }
            return values.reduce(0, +)
        }
        return ResourceSpec(cpuRequest: sum(\.cpuRequest, requireAll: false), memoryRequest: sum(\.memoryRequest, requireAll: false),
                            cpuLimit: sum(\.cpuLimit, requireAll: true), memoryLimit: sum(\.memoryLimit, requireAll: true))
    }
}

/// Evaluates a `LabelSelector` (`matchLabels` and `matchExpressions`) against labels.
public enum LabelSelector {
    /// `selector` is a workload's `spec.selector`, or a service's plain `spec.selector` map.
    public static func matches(_ selector: JSONValue?, labels: [String: String]) -> Bool {
        guard let selector else { return false }
        if selector["matchLabels"] == nil && selector["matchExpressions"] == nil {
            let plain = selector.stringMap
            return !plain.isEmpty && plain.allSatisfy { labels[$0.key] == $0.value }
        }
        let matchLabels = selector["matchLabels"]?.stringMap ?? [:]
        let expressions = selector["matchExpressions"]?.array ?? []
        if matchLabels.isEmpty && expressions.isEmpty { return false }
        guard matchLabels.allSatisfy({ labels[$0.key] == $0.value }) else { return false }
        for expression in expressions {
            guard let key = expression["key"]?.string else { return false }
            let values = Set((expression["values"]?.array ?? []).compactMap(\.string))
            switch expression["operator"]?.string {
            case "In": guard let v = labels[key], values.contains(v) else { return false }
            case "NotIn": if let v = labels[key], values.contains(v) { return false }
            case "Exists": guard labels[key] != nil else { return false }
            case "DoesNotExist": guard labels[key] == nil else { return false }
            default: return false
            }
        }
        return true
    }
}
