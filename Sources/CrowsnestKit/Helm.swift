import Foundation

/// One revision of a Helm 3 release, decoded from its storage object
/// (Secret `sh.helm.release.v1.<name>.v<revision>` or, with the ConfigMap driver, a ConfigMap labelled `owner=helm`).
public struct HelmRelease: Sendable, Identifiable, Equatable {
    public var name: String
    public var namespace: String
    public var revision: Int
    public var status: String
    public var description: String
    public var firstDeployed: Date?
    public var lastDeployed: Date?
    public var notes: String
    public var chartName: String
    public var chartVersion: String
    public var appVersion: String
    public var chartDescription: String
    /// Values supplied by the user (`helm install -f/--set`).
    public var userValues: JSONValue
    /// Default values of the chart.
    public var chartValues: JSONValue
    /// Rendered manifest (multi-document YAML).
    public var manifest: String
    /// Hook names and kinds (`helm.sh/hook`), rendered separately from the manifest.
    public var hooks: [Hook]
    /// The storage object ("Secret" or "ConfigMap") this revision was read from.
    public var storageKind: String
    public var storageName: String

    public init(name: String, namespace: String, revision: Int, status: String, description: String = "", firstDeployed: Date? = nil,
                lastDeployed: Date? = nil, notes: String = "", chartName: String, chartVersion: String, appVersion: String = "",
                chartDescription: String = "", userValues: JSONValue = .object([:]), chartValues: JSONValue = .object([:]),
                manifest: String = "", hooks: [Hook] = [], storageKind: String = "Secret", storageName: String = "") {
        self.name = name
        self.namespace = namespace
        self.revision = revision
        self.status = status
        self.description = description
        self.firstDeployed = firstDeployed
        self.lastDeployed = lastDeployed
        self.notes = notes
        self.chartName = chartName
        self.chartVersion = chartVersion
        self.appVersion = appVersion
        self.chartDescription = chartDescription
        self.userValues = userValues
        self.chartValues = chartValues
        self.manifest = manifest
        self.hooks = hooks
        self.storageKind = storageKind
        self.storageName = storageName
    }

    public struct Hook: Sendable, Equatable {
        public var name: String
        public var kind: String
        public var events: [String]
    }

    public var id: String { "\(namespace)/\(name)#\(revision)" }
    /// "namespace/name" – identifies the release across revisions.
    public var releaseKey: String { "\(namespace)/\(name)" }
    public var chart: String { "\(chartName)-\(chartVersion)" }

    /// Chart defaults overridden by the user's values, like `helm get values --all`.
    public var computedValues: JSONValue { Self.merge(chartValues, userValues) }

    /// Tone for status display.
    public var statusTone: StatusTone {
        switch status {
        case "deployed": .ok
        case "failed": .error
        case "superseded", "uninstalled": .neutral
        default: .progress  // pending-install, pending-upgrade, pending-rollback, uninstalling
        }
    }

    /// Objects rendered by the release (kind, name, namespace), parsed from the manifest.
    public var resources: [ResourceRef] {
        guard let docs = try? JSONValue.documents(yaml: manifest) else { return [] }
        return docs.compactMap { doc in
            guard let kind = doc["kind"]?.string, let name = doc.value(at: "metadata.name")?.string else { return nil }
            return ResourceRef(apiVersion: doc["apiVersion"]?.string ?? "v1", kind: kind, name: name,
                               namespace: doc.value(at: "metadata.namespace")?.string)
        }
    }

    public struct ResourceRef: Sendable, Hashable, Identifiable {
        public var apiVersion: String
        public var kind: String
        public var name: String
        /// As written in the manifest; namespaced objects without it live in the release namespace.
        public var namespace: String?
        public var id: String { "\(apiVersion)/\(kind)/\(namespace ?? "")/\(name)" }
    }

    // MARK: - Decoding

    /// Decodes a release storage object. Returns `nil` for objects that aren't Helm releases.
    public static func decode(_ object: KubeObject) throws -> HelmRelease? {
        guard object.labels["owner"] == "helm" else { return nil }
        let payload: Data
        switch object.kind {
        case "Secret":
            guard let encoded = object["data.release"]?.string, let outer = Data(base64Encoded: encoded) else { return nil }
            payload = outer
        case "ConfigMap":
            guard let text = object["data.release"]?.string else { return nil }
            payload = Data(text.utf8)
        default:
            return nil
        }
        // Helm stores base64(gzip(json)); older versions may skip gzip.
        guard let inner = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) else {
            throw KubeError.invalidInput("Helm release \(object.name): payload is not base64")
        }
        let json = Gzip.isGzip(inner) ? try Gzip.decompress(inner) : inner
        let release = try JSONValue(jsonData: json)
        return HelmRelease(json: release, storage: object)
    }

    init(json r: JSONValue, storage: KubeObject) {
        let chartMeta = r.value(at: "chart.metadata") ?? .null
        name = r["name"]?.string ?? storage.labels["name"] ?? storage.name
        namespace = r["namespace"]?.string ?? storage.namespace ?? ""
        revision = r["version"]?.int ?? Int(storage.labels["version"] ?? "") ?? 0
        status = r.value(at: "info.status")?.string ?? storage.labels["status"] ?? "unknown"
        description = r.value(at: "info.description")?.string ?? ""
        firstDeployed = r.value(at: "info.first_deployed")?.string.flatMap(KubeDate.parse)
        lastDeployed = r.value(at: "info.last_deployed")?.string.flatMap(KubeDate.parse)
        notes = r.value(at: "info.notes")?.string ?? ""
        chartName = chartMeta["name"]?.string ?? "?"
        chartVersion = chartMeta["version"]?.string ?? "?"
        appVersion = chartMeta["appVersion"]?.string ?? ""
        chartDescription = chartMeta["description"]?.string ?? ""
        userValues = r["config"] ?? .object([:])
        chartValues = r.value(at: "chart.values") ?? .object([:])
        manifest = r["manifest"]?.string ?? ""
        hooks = (r["hooks"]?.array ?? []).map { h in
            Hook(name: h["name"]?.string ?? "", kind: h["kind"]?.string ?? "",
                 events: (h["events"]?.array ?? []).compactMap(\.string))
        }
        storageKind = storage.kind
        storageName = storage.name
    }

    /// Deep merge: maps are merged recursively, everything else in `overlay` wins.
    static func merge(_ base: JSONValue, _ overlay: JSONValue) -> JSONValue {
        guard case .object(var result) = base, case .object(let top) = overlay else {
            return overlay == .null ? base : overlay
        }
        for (key, value) in top {
            if let existing = result[key], case .object = existing, case .object = value {
                result[key] = merge(existing, value)
            } else if value == .null {
                result.removeValue(forKey: key)  // `--set key=null` removes a default
            } else {
                result[key] = value
            }
        }
        return .object(result)
    }
}

extension KubeClient {
    /// All revisions of all Helm releases (Secret and ConfigMap drivers), newest revision first per release.
    public func helmRevisions(namespace: String?) async throws -> [HelmRelease] {
        async let secrets = list(.secrets, namespace: namespace, labelSelector: "owner=helm")
        async let configMaps = list(.configMaps, namespace: namespace, labelSelector: "owner=helm")
        var result: [HelmRelease] = []
        for object in try await secrets + ((try? await configMaps) ?? []) {
            if let release = try? HelmRelease.decode(object) { result.append(release) }
        }
        return result.sorted { ($0.releaseKey, $1.revision) < ($1.releaseKey, $0.revision) }
    }

    /// The latest revision of each release, like `helm list -a`.
    public func helmReleases(namespace: String?) async throws -> [HelmRelease] {
        Self.latestRevisions(try await helmRevisions(namespace: namespace))
    }

    static func latestRevisions(_ revisions: [HelmRelease]) -> [HelmRelease] {
        var latest: [String: HelmRelease] = [:]
        for r in revisions where (latest[r.releaseKey]?.revision ?? -1) < r.revision { latest[r.releaseKey] = r }
        return latest.values.sorted { ($0.namespace, $0.name) < ($1.namespace, $1.name) }
    }
}

/// Minimal gzip (RFC 1952) reader on top of the Compression framework's raw DEFLATE.
enum Gzip {
    static func isGzip(_ data: Data) -> Bool {
        data.count > 18 && data[data.startIndex] == 0x1F && data[data.startIndex + 1] == 0x8B
    }

    static func decompress(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else {
            throw KubeError.invalidInput("Not a gzip stream")
        }
        let flags = bytes[3]
        var index = 10
        if flags & 0x04 != 0 { index += 2 + Int(bytes[index]) + Int(bytes[index + 1]) << 8 }  // FEXTRA
        if flags & 0x08 != 0 { while index < bytes.count, bytes[index] != 0 { index += 1 }; index += 1 }  // FNAME
        if flags & 0x10 != 0 { while index < bytes.count, bytes[index] != 0 { index += 1 }; index += 1 }  // FCOMMENT
        if flags & 0x02 != 0 { index += 2 }  // FHCRC
        guard index < bytes.count - 8 else { throw KubeError.invalidInput("Truncated gzip stream") }
        let deflate = Data(bytes[index..<(bytes.count - 8)])
        do {
            return try (deflate as NSData).decompressed(using: .zlib) as Data
        } catch {
            throw KubeError.invalidInput("Could not decompress Helm release: \(error.localizedDescription)")
        }
    }
}

/// Line-based unified diff (for comparing revisions).
public enum TextDiff {
    public enum Line: Sendable, Equatable {
        case context(String)
        case added(String)
        case removed(String)
        /// Separator between hunks ("@@ … @@").
        case hunk(String)
    }

    /// Unified diff with `context` unchanged lines around each change; empty if equal.
    public static func unified(old: String, new: String, context: Int = 3) -> [Line] {
        let a = old.components(separatedBy: "\n"), b = new.components(separatedBy: "\n")
        let diff = b.difference(from: a)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        // Full annotated sequence with positions in old/new.
        var all: [(line: Line, oldLine: Int, newLine: Int)] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) {
                all.append((.removed(a[i]), i, j)); i += 1
            } else if j < b.count, inserted.contains(j) {
                all.append((.added(b[j]), i, j)); j += 1
            } else {
                all.append((.context(i < a.count ? a[i] : b[j]), i, j)); i += 1; j += 1
            }
        }
        // Keep changes plus `context` lines around them.
        let changed = all.indices.filter { if case .context = all[$0].line { return false }; return true }
        guard !changed.isEmpty else { return [] }
        var keep = Set<Int>()
        for c in changed { for k in max(0, c - context)...min(all.count - 1, c + context) { keep.insert(k) } }
        var result: [Line] = []
        var previous = -2
        for k in keep.sorted() {
            if k != previous + 1 {
                result.append(.hunk("@@ -\(all[k].oldLine + 1) +\(all[k].newLine + 1) @@"))
            }
            result.append(all[k].line)
            previous = k
        }
        return result
    }
}
