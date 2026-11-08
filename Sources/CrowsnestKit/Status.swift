import Foundation

/// Coarse health classification used for coloring.
public enum StatusTone: String, Sendable, Hashable {
    case ok, progress, warning, error, neutral
}

/// Status derivations that mirror what `kubectl get` prints.
public enum PodStatus {
    public static func status(of pod: KubeObject) -> (text: String, tone: StatusTone) {
        if pod.deletionTimestamp != nil {
            return ("Terminating", .progress)
        }
        let phase = pod["status.phase"]?.string ?? "Unknown"
        if let reason = pod["status.reason"]?.string, phase != "Running" {
            return (reason, reason == "Evicted" ? .error : .warning)
        }

        let initStatuses = pod["status.initContainerStatuses"]?.array ?? []
        let initCount = (pod["spec.initContainers"]?.array ?? []).count
        for (index, cs) in initStatuses.enumerated() {
            if let t = cs["state"]?["terminated"], t["exitCode"]?.int == 0 { continue }
            if let t = cs["state"]?["terminated"] {
                let reason = t["reason"]?.string ?? "Error"
                return ("Init:\(reason)", .error)
            }
            if let w = cs["state"]?["waiting"], let reason = w["reason"]?.string, reason != "PodInitializing" {
                return ("Init:\(reason)", tone(forWaitingReason: reason))
            }
            return ("Init:\(index)/\(initCount)", .progress)
        }

        var result: (String, StatusTone) = (phase, tone(forPhase: phase))
        var anyRunning = false
        for cs in (pod["status.containerStatuses"]?.array ?? []).reversed() {
            if let w = cs["state"]?["waiting"], let reason = w["reason"]?.string {
                result = (reason, tone(forWaitingReason: reason))
            } else if let t = cs["state"]?["terminated"] {
                let reason = t["reason"]?.string ?? "ExitCode:\(t["exitCode"]?.int ?? 0)"
                result = (reason, reason == "Completed" ? .neutral : .error)
            } else if cs["state"]?["running"] != nil, cs["ready"]?.bool == true {
                anyRunning = true
            }
        }
        if result.0 == "Completed", anyRunning { return ("Running", .ok) }
        if phase == "Running", result.0 == "Running" {
            let (ready, total) = readiness(of: pod)
            return ("Running", ready == total ? .ok : .warning)
        }
        return result
    }

    public static func readiness(of pod: KubeObject) -> (ready: Int, total: Int) {
        let statuses = pod["status.containerStatuses"]?.array ?? []
        let total = (pod["spec.containers"]?.array ?? []).count
        return (statuses.filter { $0["ready"]?.bool == true }.count, total)
    }

    public static func restarts(of pod: KubeObject) -> Int {
        (pod["status.containerStatuses"]?.array ?? []).reduce(0) { $0 + ($1["restartCount"]?.int ?? 0) }
    }

    public static func containerNames(of pod: KubeObject, includeInit: Bool = true) -> [String] {
        let main = (pod["spec.containers"]?.array ?? []).compactMap { $0["name"]?.string }
        guard includeInit else { return main }
        let initC = (pod["spec.initContainers"]?.array ?? []).compactMap { $0["name"]?.string }
        let eph = (pod["spec.ephemeralContainers"]?.array ?? []).compactMap { $0["name"]?.string }
        return main + initC + eph
    }

    static func tone(forPhase phase: String) -> StatusTone {
        switch phase {
        case "Running": .ok
        case "Succeeded": .neutral
        case "Pending": .progress
        case "Failed": .error
        default: .warning
        }
    }

    static func tone(forWaitingReason reason: String) -> StatusTone {
        switch reason {
        case "ContainerCreating", "PodInitializing": .progress
        case "CrashLoopBackOff", "ImagePullBackOff", "ErrImagePull", "CreateContainerConfigError",
             "InvalidImageName", "CreateContainerError", "RunContainerError":
            .error
        default: .warning
        }
    }
}

public enum NodeStatus {
    public static func status(of node: KubeObject) -> (text: String, tone: StatusTone) {
        let ready = node.conditions.first { $0.type == "Ready" }
        var parts: [String] = []
        let tone: StatusTone
        switch ready?.status {
        case "True": parts.append("Ready"); tone = .ok
        case "False": parts.append("NotReady"); tone = .error
        default: parts.append("Unknown"); tone = .warning
        }
        if node["spec.unschedulable"]?.bool == true { parts.append("SchedulingDisabled") }
        for c in node.conditions where c.type != "Ready" && c.status == "True" { parts.append(c.type) }
        return (parts.joined(separator: ", "), parts.count > 1 && tone == .ok ? .warning : tone)
    }

    public static func roles(of node: KubeObject) -> String {
        let roles = node.labels.keys
            .filter { $0.hasPrefix("node-role.kubernetes.io/") }
            .map { String($0.dropFirst("node-role.kubernetes.io/".count)) }
            .sorted()
        return roles.isEmpty ? "<none>" : roles.joined(separator: ",")
    }

    public static func address(of node: KubeObject, type: String) -> String? {
        node["status.addresses"]?.array?.first { $0["type"]?.string == type }?["address"]?.string
    }
}

public enum WorkloadStatus {
    /// Tone for objects with desired/ready replica counts.
    public static func tone(ready: Int, desired: Int) -> StatusTone {
        if desired == 0 { return .neutral }
        if ready >= desired { return .ok }
        if ready == 0 { return .error }
        return .warning
    }
}

/// Parses Kubernetes resource quantities ("250m", "1Gi", "128974848", "1.5").
public enum Quantity {
    public static func parse(_ string: String) -> Double? {
        let s = string.trimmingCharacters(in: .whitespaces)
        let suffixes: [(String, Double)] = [
            ("Ki", 1024), ("Mi", pow(1024, 2)), ("Gi", pow(1024, 3)), ("Ti", pow(1024, 4)), ("Pi", pow(1024, 5)), ("Ei", pow(1024, 6)),
            ("n", 1e-9), ("u", 1e-6), ("m", 1e-3), ("k", 1e3), ("M", 1e6), ("G", 1e9), ("T", 1e12), ("P", 1e15), ("E", 1e18),
        ]
        for (suffix, factor) in suffixes where s.hasSuffix(suffix) {
            return Double(s.dropLast(suffix.count)).map { $0 * factor }
        }
        return Double(s)
    }

    public static func formatBytes(_ bytes: Double) -> String {
        let units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
        var value = bytes, unit = 0
        while value >= 1024, unit < units.count - 1 { value /= 1024; unit += 1 }
        return unit == 0 ? "\(Int(value)) B" : String(format: value < 10 ? "%.1f %@" : "%.0f %@", value, units[unit])
    }

    public static func formatCPU(_ cores: Double) -> String {
        let millis = cores * 1000
        if cores >= 1 { return String(format: "%.2f", cores) }
        if millis > 0 && millis < 1 { return String(format: "%.2fm", millis) }
        if millis > 0 && millis < 10 && millis.rounded() != millis { return String(format: "%.1fm", millis) }
        return "\(Int(millis.rounded()))m"
    }
}
