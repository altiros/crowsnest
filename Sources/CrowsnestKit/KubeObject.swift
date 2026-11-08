import Foundation

/// A Kubernetes object of any kind, backed by its raw JSON.
public struct KubeObject: Sendable, Identifiable, Hashable {
    public var raw: JSONValue

    public init(_ raw: JSONValue) { self.raw = raw }

    public var id: String {
        if let uid, !uid.isEmpty { return uid }
        return [kind, namespace ?? "", name].joined(separator: "/")
    }

    public subscript(path: String) -> JSONValue? { raw.value(at: path) }

    public var kind: String { raw["kind"]?.string ?? "" }
    public var apiVersion: String { raw["apiVersion"]?.string ?? "" }
    public var metadata: JSONValue { raw["metadata"] ?? .object([:]) }
    public var name: String { metadata["name"]?.string ?? "" }
    public var namespace: String? { metadata["namespace"]?.string }
    public var uid: String? { metadata["uid"]?.string }
    public var resourceVersion: String? { metadata["resourceVersion"]?.string }
    public var labels: [String: String] { metadata["labels"]?.stringMap ?? [:] }
    public var annotations: [String: String] { metadata["annotations"]?.stringMap ?? [:] }
    public var creationTimestamp: Date? { metadata["creationTimestamp"]?.string.flatMap(KubeDate.parse) }
    public var deletionTimestamp: Date? { metadata["deletionTimestamp"]?.string.flatMap(KubeDate.parse) }
    public var ownerReferences: [JSONValue] { metadata["ownerReferences"]?.array ?? [] }

    /// `status.conditions`, normalized.
    public var conditions: [Condition] {
        (raw.value(at: "status.conditions")?.array ?? []).map(Condition.init)
    }

    public struct Condition: Sendable, Hashable, Identifiable {
        public var type: String
        public var status: String
        public var reason: String?
        public var message: String?
        public var lastTransition: Date?
        public var id: String { type }

        init(_ json: JSONValue) {
            type = json["type"]?.string ?? "?"
            status = json["status"]?.string ?? "Unknown"
            reason = json["reason"]?.string
            message = json["message"]?.string
            lastTransition = (json["lastTransitionTime"] ?? json["lastUpdateTime"])?.string.flatMap(KubeDate.parse)
        }
    }

    /// Copy without server-managed noise, as `kubectl get -o yaml` shows it.
    public var cleanedForDisplay: JSONValue {
        var copy = raw
        copy.set(nil, at: ["metadata", "managedFields"])
        return copy
    }

    public static func == (lhs: KubeObject, rhs: KubeObject) -> Bool {
        lhs.id == rhs.id && lhs.resourceVersion == rhs.resourceVersion && lhs.raw == rhs.raw
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(resourceVersion)
    }
}

public enum KubeDate {
    public static func parse(_ string: String) -> Date? {
        if let d = try? Date(string, strategy: .iso8601) { return d }
        return try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    /// Short age like kubectl's `AGE` column: `45s`, `5m12s`, `3h`, `2d5h`, `120d`, `2y3d`.
    public static func age(since date: Date?, now: Date = .now) -> String {
        guard let date else { return "–" }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        let minutes = seconds / 60, hours = minutes / 60, days = hours / 24
        switch seconds {
        case ..<120: return "\(seconds)s"
        case ..<600: return seconds % 60 == 0 ? "\(minutes)m" : "\(minutes)m\(seconds % 60)s"
        case ..<(3 * 3600): return "\(minutes)m"
        case ..<(8 * 3600): return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h\(minutes % 60)m"
        case ..<(48 * 3600): return "\(hours)h"
        case ..<(8 * 86400): return hours % 24 == 0 ? "\(days)d" : "\(days)d\(hours % 24)h"
        case ..<(2 * 365 * 86400): return "\(days)d"
        default:
            let years = days / 365
            return days % 365 == 0 ? "\(years)y" : "\(years)y\(days % 365)d"
        }
    }
}
