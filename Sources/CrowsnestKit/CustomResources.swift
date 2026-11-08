import Foundation

extension ResourceKind {
    /// Builds a kind from a CustomResourceDefinition, using its storage (or first served)
    /// version and its `additionalPrinterColumns`, like `kubectl get` and Lens do.
    public init?(crd: KubeObject) {
        guard let group = crd["spec.group"]?.string,
              let plural = crd["spec.names.plural"]?.string,
              let kind = crd["spec.names.kind"]?.string else { return nil }
        let versions = crd["spec.versions"]?.array ?? []
        guard let version = versions.first(where: { $0["storage"]?.bool == true && $0["served"]?.bool != false })
            ?? versions.first(where: { $0["served"]?.bool == true }),
            let versionName = version["name"]?.string else { return nil }

        var columns: [ResourceColumn] = []
        for col in version["additionalPrinterColumns"]?.array ?? [] {
            guard let name = col["name"]?.string, let jsonPath = col["jsonPath"]?.string else { continue }
            if (col["priority"]?.int ?? 0) > 0 { continue }
            let type = col["type"]?.string ?? "string"
            let path = JSONPath(jsonPath)
            let id = name == "Age" ? "Age" : "crd:\(name)"
            columns.append(ResourceColumn(name, id: id) { o in
                let values = path.evaluate(o.raw)
                switch type {
                case "date":
                    return .age(values.first?.string.flatMap(KubeDate.parse))
                case "integer":
                    return values.count == 1 ? .number(values[0].int ?? 0) : .text(values.compactMap(\.string).joined(separator: ","))
                default:
                    return .text(values.compactMap(\.string).joined(separator: ","))
                }
            })
        }

        self.init(
            kind: kind, group: group, version: versionName, plural: plural,
            namespaced: crd["spec.scope"]?.string != "Cluster",
            title: kind, category: .customResources, symbol: "puzzlepiece", columns: columns
        )
    }
}

/// Minimal JSONPath evaluator covering what CRD printer columns use:
/// `.a.b`, `.a[0]`, `.a[*].b`, `.a[?(@.type=="Ready")].status`, `['dotted.key']`.
public struct JSONPath: Sendable {
    enum Step: Sendable {
        case key(String)
        case index(Int)
        case wildcard
        case filter(key: [String], equals: String)
    }

    let steps: [Step]

    public init(_ expression: String) {
        var s = Substring(expression.trimmingCharacters(in: CharacterSet(charactersIn: "{} ")))
        if s.hasPrefix("$") { s = s.dropFirst() }
        var steps: [Step] = []
        while !s.isEmpty {
            if s.hasPrefix(".") {
                s = s.dropFirst()
                let end = s.firstIndex(where: { $0 == "." || $0 == "[" }) ?? s.endIndex
                if end > s.startIndex { steps.append(.key(String(s[..<end]))) }
                s = s[end...]
            } else if s.hasPrefix("[") {
                guard let close = JSONPath.closingBracket(in: s) else { break }
                let inner = s[s.index(after: s.startIndex)..<close].trimmingCharacters(in: .whitespaces)
                s = s[s.index(after: close)...]
                if inner == "*" {
                    steps.append(.wildcard)
                } else if let i = Int(inner) {
                    steps.append(.index(i))
                } else if inner.hasPrefix("'") || inner.hasPrefix("\"") {
                    steps.append(.key(String(inner.dropFirst().dropLast())))
                } else if inner.hasPrefix("?(@."), inner.hasSuffix(")") {
                    let body = inner.dropFirst(4).dropLast()
                    let parts = body.components(separatedBy: "==")
                    if parts.count == 2 {
                        let key = parts[0].trimmingCharacters(in: .whitespaces).split(separator: ".").map(String.init)
                        let value = parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                        steps.append(.filter(key: key, equals: value))
                    }
                }
            } else {
                let end = s.firstIndex(where: { $0 == "." || $0 == "[" }) ?? s.endIndex
                steps.append(.key(String(s[..<end])))
                s = s[end...]
            }
        }
        self.steps = steps
    }

    private static func closingBracket(in s: Substring) -> Substring.Index? {
        var depth = 0
        var quote: Character?
        for i in s.indices {
            let c = s[i]
            if let q = quote { if c == q { quote = nil }; continue }
            if c == "'" || c == "\"" { quote = c; continue }
            if c == "[" { depth += 1 }
            if c == "]" { depth -= 1; if depth == 0 { return i } }
        }
        return nil
    }

    public func evaluate(_ root: JSONValue) -> [JSONValue] {
        var current = [root]
        for step in steps {
            var next: [JSONValue] = []
            for value in current {
                switch step {
                case .key(let k):
                    if let v = value[k] { next.append(v) }
                case .index(let i):
                    if let a = value.array {
                        let idx = i < 0 ? a.count + i : i
                        if a.indices.contains(idx) { next.append(a[idx]) }
                    }
                case .wildcard:
                    if let a = value.array { next += a } else if let o = value.object { next += o.values }
                case .filter(let key, let equals):
                    for item in value.array ?? [] where item.value(at: key.joined(separator: "."))?.string == equals {
                        next.append(item)
                    }
                }
            }
            current = next
        }
        return current
    }
}
