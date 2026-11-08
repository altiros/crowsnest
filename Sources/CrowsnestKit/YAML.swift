import Foundation
import Yams

/// YAML <-> JSONValue conversion with kubectl-like key ordering.
extension JSONValue {
    /// Keys that kubectl-style output shows first, in this order.
    private static let priorityKeys = ["apiVersion", "kind", "metadata", "name", "namespace", "spec", "data", "stringData", "type", "status"]

    static func orderedKeys(_ keys: some Collection<String>) -> [String] {
        keys.sorted { a, b in
            let ia = priorityKeys.firstIndex(of: a) ?? Int.max
            let ib = priorityKeys.firstIndex(of: b) ?? Int.max
            return ia != ib ? ia < ib : a < b
        }
    }

    public func yamlString() throws -> String {
        try Yams.serialize(node: yamlNode(), indent: 2, width: -1, allowUnicode: true)
    }

    func yamlNode() -> Node {
        switch self {
        case .null:
            return Node("null", Tag(.null))
        case .bool(let b):
            return Node(b ? "true" : "false", Tag(.bool))
        case .int(let i):
            return Node(String(i), Tag(.int))
        case .double(let d):
            let text = d.rounded() == d && abs(d) < 1e15 ? String(format: "%.1f", d) : String(d)
            return Node(text, Tag(.float))
        case .string(let s):
            if s.contains("\n") {
                return .scalar(.init(s, Tag(.str), .literal))
            }
            // Quote strings that would otherwise be read back as another type.
            let needsQuotes = s.isEmpty || Resolver.default.resolveTag(of: Node(s)) != .str
            return .scalar(.init(s, Tag(.str), needsQuotes ? .doubleQuoted : .any))
        case .array(let a):
            return .sequence(.init(a.map { $0.yamlNode() }))
        case .object(let o):
            let pairs = JSONValue.orderedKeys(o.keys).map { (Node($0, Tag(.str)), o[$0]!.yamlNode()) }
            return .mapping(.init(pairs))
        }
    }

    /// Parses a single YAML document.
    public init(yaml: String) throws {
        guard let node = try Yams.compose(yaml: yaml) else {
            self = .null
            return
        }
        self = try JSONValue(yamlNode: node)
    }

    init(yamlNode node: Node) throws {
        switch node {
        case .scalar(let scalar):
            let isPlain = scalar.style == .plain || scalar.style == .any
            let tag: Tag.Name = isPlain ? Resolver.default.resolveTag(of: Node(scalar.string)) : .str
            switch tag {
            case .null:
                self = .null
            case .bool:
                self = Bool.construct(from: scalar).map(JSONValue.bool) ?? .string(scalar.string)
            case .int:
                if let i = Int.construct(from: scalar) { self = .int(Int64(i)) } else { self = .string(scalar.string) }
            case .float:
                self = Double.construct(from: scalar).map(JSONValue.double) ?? .string(scalar.string)
            default:
                self = .string(scalar.string)
            }
        case .sequence(let seq):
            self = .array(try seq.map { try JSONValue(yamlNode: $0) })
        case .mapping(let map):
            var dict: [String: JSONValue] = [:]
            for (key, value) in map {
                guard let k = key.string else { throw KubeError.invalidInput("Unsupported YAML key") }
                dict[k] = try JSONValue(yamlNode: value)
            }
            self = .object(dict)
        case .alias:
            throw KubeError.invalidInput("YAML aliases are not supported")
        }
    }
}

/// A YAML syntax error with position (1-based), for showing in an editor.
public struct YAMLSyntaxError: Error, LocalizedError, Sendable, Equatable {
    public var line: Int?
    public var column: Int?
    public var message: String

    public init(line: Int? = nil, column: Int? = nil, message: String) {
        self.line = line
        self.column = column
        self.message = message
    }

    init(_ error: Error) {
        if let e = error as? YamlError {
            switch e {
            case let .scanner(context, problem, mark, _), let .parser(context, problem, mark, _), let .composer(context, problem, mark, _):
                let detail = [context.map { String(describing: $0) }, problem].compactMap { $0 }.joined(separator: ": ")
                self.init(line: mark.line, column: mark.column, message: detail)
                return
            default:
                break
            }
        }
        if let e = error as? KubeError {
            self.init(message: e.localizedDescription)
            return
        }
        self.init(message: String(describing: error))
    }

    public var errorDescription: String? {
        guard let line else { return message }
        return "Line \(line)\(column.map { ", column \($0)" } ?? ""): \(message)"
    }
}

extension JSONValue {
    /// Parses a multi-document YAML stream (`---` separated). Empty documents are skipped.
    public static func documents(yaml: String) throws(YAMLSyntaxError) -> [JSONValue] {
        do {
            let parser = try Parser(yaml: yaml)
            var result: [JSONValue] = []
            while let node = try parser.nextRoot() {
                let value = try JSONValue(yamlNode: node)
                if !value.isNull { result.append(value) }
            }
            return result
        } catch {
            throw YAMLSyntaxError(error)
        }
    }

    /// Serializes several objects as one multi-document YAML stream.
    public static func yamlStream(_ values: [JSONValue]) throws -> String {
        try values.map { try $0.yamlString() }.joined(separator: "---\n")
    }
}
