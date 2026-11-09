import Foundation

/// A displayable table cell value.
public enum CellValue: Sendable, Hashable {
    case text(String)
    case number(Int)
    case age(Date?)
    case status(String, StatusTone)
    /// A measured amount (e.g. CPU or memory usage): sorts by `value`, shows `text`,
    /// and a small bar when `fraction` (0…1, of a limit or capacity) is known.
    case meter(value: Double, fraction: Double?, text: String)

    public func display(now: Date = .now) -> String {
        switch self {
        case .text(let s): s
        case .number(let n): String(n)
        case .age(let d): KubeDate.age(since: d, now: now)
        case .status(let s, _): s
        case .meter(_, let fraction, let text): fraction.map { "\(text) (\(Int(($0 * 100).rounded())) %)" } ?? text
        }
    }

    public static func compare(_ a: CellValue, _ b: CellValue) -> ComparisonResult {
        switch (a, b) {
        case (.number(let x), .number(let y)):
            return x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
        case (.meter(let x, _, _), .meter(let y, _, _)):
            return x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
        case (.meter, _):
            return .orderedDescending
        case (_, .meter):
            return .orderedAscending
        case (.age(let x), .age(let y)):
            // Younger objects (later dates) first in ascending order, like "smallest age first".
            let dx = x ?? .distantPast, dy = y ?? .distantPast
            return dx == dy ? .orderedSame : (dx > dy ? .orderedAscending : .orderedDescending)
        case (.text(let x), .text(let y)):
            // Kubernetes quantities ("500m", "2", "16Gi", "512Mi") compare by value, not as text.
            switch (Quantity.parse(x), Quantity.parse(y)) {
            case let (qx?, qy?):
                return qx == qy ? .orderedSame : (qx < qy ? .orderedAscending : .orderedDescending)
            case (.some, nil):
                return .orderedAscending
            case (nil, .some):
                return .orderedDescending
            case (nil, nil):
                return x.localizedStandardCompare(y)
            }
        default:
            return a.display().localizedStandardCompare(b.display())
        }
    }
}

public struct ResourceColumn: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let width: Width
    public let value: @Sendable (KubeObject) -> CellValue

    public enum Width: Sendable { case narrow, normal, wide }

    public init(_ title: String, id: String? = nil, width: Width = .normal, value: @escaping @Sendable (KubeObject) -> CellValue) {
        self.id = id ?? title
        self.title = title
        self.width = width
        self.value = value
    }
}

/// Sidebar groups, following the navigation of Lens.
public enum ResourceCategory: String, Sendable, CaseIterable, Identifiable {
    case cluster = "Cluster"
    case workloads = "Workloads"
    case config = "Config"
    case network = "Network"
    case storage = "Storage"
    case accessControl = "Access Control"
    case customResources = "Custom Resources"

    public var id: String { rawValue }
}

/// Describes one API resource type (built-in or custom) and how to list it.
public struct ResourceKind: Sendable, Identifiable, Hashable {
    public var kind: String
    public var group: String
    public var version: String
    public var plural: String
    public var namespaced: Bool
    public var title: String
    public var category: ResourceCategory
    public var symbol: String
    public var columns: [ResourceColumn]
    public var capabilities: Set<Capability>

    public enum Capability: Sendable, Hashable {
        case logs, scale, restart, shell
    }

    public init(kind: String, group: String = "", version: String = "v1", plural: String, namespaced: Bool = true,
                title: String? = nil, category: ResourceCategory, symbol: String = "cube",
                columns: [ResourceColumn] = [], capabilities: Set<Capability> = []) {
        self.kind = kind
        self.group = group
        self.version = version
        self.plural = plural
        self.namespaced = namespaced
        self.title = title ?? plural.capitalized
        self.category = category
        self.symbol = symbol
        self.columns = columns
        self.capabilities = capabilities
    }

    public var id: String { group.isEmpty ? plural : "\(plural).\(group)" }
    public var apiVersion: String { group.isEmpty ? version : "\(group)/\(version)" }

    /// Name (+ namespace) columns followed by the kind-specific ones.
    public var allColumns: [ResourceColumn] {
        var result = [ResourceColumn("Name", width: .wide) { .text($0.name) }]
        if namespaced { result.append(ResourceColumn("Namespace") { .text($0.namespace ?? "") }) }
        result += columns
        if !columns.contains(where: { $0.id == "Age" }) {
            result.append(ResourceColumn("Age", width: .narrow) { .age($0.creationTimestamp) })
        }
        return result
    }

    /// REST path for a collection or (with `name`) a single object.
    public func path(namespace: String? = nil, name: String? = nil, subresource: String? = nil) -> String {
        var p = group.isEmpty ? "/api/\(version)" : "/apis/\(group)/\(version)"
        if namespaced, let namespace, !namespace.isEmpty { p += "/namespaces/\(namespace)" }
        p += "/\(plural)"
        if let name { p += "/\(name)" }
        if let subresource { p += "/\(subresource)" }
        return p
    }

    public static func == (lhs: ResourceKind, rhs: ResourceKind) -> Bool { lhs.id == rhs.id && lhs.version == rhs.version }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
