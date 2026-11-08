import Foundation

/// Validation of manifests before sending them to the API server.
public enum ManifestIssue: Sendable, Equatable, LocalizedError {
    case notAnObject(document: Int)
    case missingField(document: Int, field: String)

    public var errorDescription: String? {
        switch self {
        case .notAnObject(let d): "Document \(d): not a Kubernetes object"
        case .missingField(let d, let f): "Document \(d): field \"\(f)\" is missing"
        }
    }

    /// Client-side checks: each document needs apiVersion, kind and a name (or generateName).
    public static func check(_ documents: [JSONValue]) -> [ManifestIssue] {
        var issues: [ManifestIssue] = []
        for (i, doc) in documents.enumerated() {
            let n = i + 1
            guard doc.object != nil else { issues.append(.notAnObject(document: n)); continue }
            if doc["apiVersion"]?.string?.isEmpty ?? true { issues.append(.missingField(document: n, field: "apiVersion")) }
            if doc["kind"]?.string?.isEmpty ?? true { issues.append(.missingField(document: n, field: "kind")) }
            let name = doc.value(at: "metadata.name")?.string ?? doc.value(at: "metadata.generateName")?.string
            if name?.isEmpty ?? true { issues.append(.missingField(document: n, field: "metadata.name")) }
        }
        return issues
    }
}

extension KubeClient {
    /// Finds the REST resource for `apiVersion` + `kind`, using the built-in catalog
    /// first and API discovery for everything else (CRDs, aggregated APIs, other versions).
    public func resolveKind(apiVersion: String, kind: String) async throws -> ResourceKind {
        let parts = apiVersion.split(separator: "/", maxSplits: 1).map(String.init)
        let group = parts.count == 2 ? parts[0] : ""
        let version = parts.last ?? "v1"
        let cacheKey = "\(apiVersion)/\(kind)"
        if let cached = discoveredKinds[cacheKey] { return cached }

        if var known = ResourceKind.builtin.first(where: { $0.kind == kind && $0.group == group }) {
            known.version = version
            discoveredKinds[cacheKey] = known
            return known
        }

        let path = group.isEmpty ? "/api/\(version)" : "/apis/\(group)/\(version)"
        let list: JSONValue
        do {
            list = try await json(path: path)
        } catch let e as KubeError where e.httpStatus == 404 {
            throw KubeError.invalidInput("API version \"\(apiVersion)\" is not available in this cluster")
        }
        guard let resource = (list["resources"]?.array ?? []).first(where: {
            $0["kind"]?.string == kind && !($0["name"]?.string ?? "/").contains("/")
        }), let plural = resource["name"]?.string else {
            throw KubeError.invalidInput("Kind \"\(kind)\" does not exist in \(apiVersion)")
        }
        let resolved = ResourceKind(kind: kind, group: group, version: version, plural: plural,
                                    namespaced: resource["namespaced"]?.bool ?? true, title: kind, category: .customResources)
        discoveredKinds[cacheKey] = resolved
        return resolved
    }

    public struct ApplyResult: Sendable {
        public var object: KubeObject
        public var kind: ResourceKind
        public var created: Bool
    }

    /// Like `kubectl apply --server-side`: creates or updates the object.
    /// Objects with only `generateName` are created with POST.
    public func apply(_ manifest: JSONValue, defaultNamespace: String?, dryRun: Bool = false,
                      force: Bool = false, fieldManager: String = "crowsnest") async throws -> ApplyResult {
        guard let apiVersion = manifest["apiVersion"]?.string, let kindName = manifest["kind"]?.string else {
            throw KubeError.invalidInput("apiVersion and kind are required")
        }
        let kind = try await resolveKind(apiVersion: apiVersion, kind: kindName)
        var body = manifest
        body.set(nil, at: ["metadata", "managedFields"])
        var namespace: String?
        if kind.namespaced {
            namespace = body.value(at: "metadata.namespace")?.string ?? defaultNamespace ?? "default"
            body.set(.string(namespace!), at: ["metadata", "namespace"])
        } else {
            body.set(nil, at: ["metadata", "namespace"])
        }
        var query = ["fieldManager": fieldManager]
        if dryRun { query["dryRun"] = "All" }

        guard let name = body.value(at: "metadata.name")?.string, !name.isEmpty else {
            let created = KubeObject(try await json(.post, path: kind.path(namespace: namespace), query: query, body: body))
            return ApplyResult(object: created, kind: kind, created: true)
        }
        if force { query["force"] = "true" }
        let existedBefore = (try? await send(.get, path: kind.path(namespace: namespace, name: name))) != nil
        let result = KubeObject(try await json(.patch, path: kind.path(namespace: namespace, name: name), query: query,
                                               body: body, contentType: "application/apply-patch+yaml"))
        return ApplyResult(object: result, kind: kind, created: !existedBefore)
    }

    /// `PUT` with optional server-side dry run (validation without persisting).
    @discardableResult
    public func replace(_ kind: ResourceKind, object: JSONValue, dryRun: Bool) async throws -> KubeObject {
        guard let name = object.value(at: "metadata.name")?.string else {
            throw KubeError.invalidInput("metadata.name is missing")
        }
        let ns = object.value(at: "metadata.namespace")?.string
        return KubeObject(try await json(.put, path: kind.path(namespace: ns, name: name),
                                         query: dryRun ? ["dryRun": "All"] : [:], body: object))
    }
}
