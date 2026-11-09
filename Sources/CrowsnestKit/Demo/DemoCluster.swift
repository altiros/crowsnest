import Foundation

/// The built-in "Demo Cluster": a simulated Kubernetes API server held in memory.
///
/// It answers the REST calls of ``KubeClient`` like a real API server – lists with label and field selectors,
/// get/create/replace/patch/delete, logs and metrics – and runs tiny controllers (Deployment → ReplicaSet → Pod,
/// StatefulSet, DaemonSet, Job, Endpoints), so scaling, restarting and deleting behave as expected.
/// Used to try Crowsnest without a cluster (and for App Review). Changes live until the app quits.
public actor DemoCluster {
    /// Context name of the demo cluster in the context list.
    public static let contextName = "Demo Cluster"
    static let host = "demo.crowsnest.invalid"

    private var state: DemoState

    public init(now: Date = .now) {
        state = DemoState(now: now)
    }

    func handle(_ method: KubeClient.Method, path: String, query: [String: String], body: Data?,
                contentType: String, now: Date = .now) throws -> Data {
        try state.handle(method, path: path, query: query, body: body, contentType: contentType, now: now)
    }

    /// The newest log line of a container (for `follow`), or nil while the container writes nothing.
    func liveLogLine(pod: String, namespace: String, container: String?, now: Date = .now) throws -> String? {
        try state.liveLogLine(pod: pod, namespace: namespace, container: container, now: now)
    }
}

extension ConnectionConfig {
    /// The demo cluster's connection (no network access).
    public static var demo: ConnectionConfig {
        ConnectionConfig(contextName: DemoCluster.contextName, clusterName: "demo", userName: "demo",
                         server: URL(string: "https://\(DemoCluster.host)")!, defaultNamespace: nil)
    }

    public var isDemo: Bool { server.host == DemoCluster.host }
}

extension KubeConfig {
    /// This kubeconfig plus the demo cluster's context (appended last).
    public func addingDemoContext() -> KubeConfig {
        guard !contextNames.contains(DemoCluster.contextName) else { return self }
        var config = self
        config.clusters.append(NamedCluster(name: "crowsnest-demo", cluster: Cluster(server: "https://\(DemoCluster.host)")))
        config.users.append(NamedUser(name: "crowsnest-demo", user: User()))
        config.contexts.append(NamedContext(name: DemoCluster.contextName, context: Context(cluster: "crowsnest-demo", user: "crowsnest-demo")))
        return config
    }
}

// MARK: - State

struct DemoState {
    struct Res: Hashable {
        var group: String
        var plural: String
        static let pods = Res(group: "", plural: "pods")
        static let nodes = Res(group: "", plural: "nodes")
        static let namespaces = Res(group: "", plural: "namespaces")
        static let events = Res(group: "", plural: "events")
        static let services = Res(group: "", plural: "services")
        static let endpoints = Res(group: "", plural: "endpoints")
        static let pvcs = Res(group: "", plural: "persistentvolumeclaims")
        static let pvs = Res(group: "", plural: "persistentvolumes")
        static let deployments = Res(group: "apps", plural: "deployments")
        static let replicaSets = Res(group: "apps", plural: "replicasets")
        static let statefulSets = Res(group: "apps", plural: "statefulsets")
        static let daemonSets = Res(group: "apps", plural: "daemonsets")
        static let jobs = Res(group: "batch", plural: "jobs")
    }

    /// resource → "namespace/name" → object
    private(set) var objects: [Res: [String: JSONValue]] = [:]
    /// Pod uid → when its containers are ready (or, for Job pods, finished).
    private var readyAt: [String: Date] = [:]
    private var rng = SplitMix64(seed: 0x00C0_FFEE)
    private var resourceVersion = 4711
    let start: Date

    init(now: Date) {
        start = now
        for object in DemoFixtures.objects(now: now) { put(object, now: now) }
        reconcile(now: now, initial: true)
        DemoFixtures.seedEvents(into: &self, now: now)
    }

    // MARK: Store

    static func res(apiVersion: String, kind: String) -> Res? {
        let group = apiVersion.contains("/") ? String(apiVersion.split(separator: "/")[0]) : ""
        return ResourceKind.builtin.first { $0.kind == kind && $0.group == group }.map { Res(group: group, plural: $0.plural) }
    }

    static func resourceKind(_ res: Res) -> ResourceKind? {
        ResourceKind.builtin.first { $0.group == res.group && $0.plural == res.plural }
    }

    static func key(_ namespace: String?, _ name: String) -> String { "\(namespace ?? "")/\(name)" }

    func get(_ res: Res, _ namespace: String?, _ name: String) -> JSONValue? {
        objects[res]?[Self.key(namespace, name)]
    }

    func all(_ res: Res, namespace: String? = nil) -> [JSONValue] {
        (objects[res] ?? [:]).values
            .filter { namespace == nil || $0.value(at: "metadata.namespace")?.string == namespace }
            .sorted { Self.sortKey($0) < Self.sortKey($1) }
    }

    private static func sortKey(_ o: JSONValue) -> String {
        "\(o.value(at: "metadata.namespace")?.string ?? "")/\(o.value(at: "metadata.name")?.string ?? "")"
    }

    /// Stores an object, filling in uid, resourceVersion and creationTimestamp when missing.
    @discardableResult
    mutating func put(_ object: JSONValue, now: Date) -> JSONValue {
        var o = object
        guard let apiVersion = o["apiVersion"]?.string, let kind = o["kind"]?.string,
              let res = Self.res(apiVersion: apiVersion, kind: kind),
              let name = o.value(at: "metadata.name")?.string else { return o }
        if o.value(at: "metadata.uid") == nil { o.set(.string(uuid()), at: ["metadata", "uid"]) }
        if o.value(at: "metadata.creationTimestamp") == nil { o.set(.string(now.kubeString), at: ["metadata", "creationTimestamp"]) }
        resourceVersion += 1
        o.set(.string(String(resourceVersion)), at: ["metadata", "resourceVersion"])
        objects[res, default: [:]][Self.key(o.value(at: "metadata.namespace")?.string, name)] = o
        return o
    }

    @discardableResult
    mutating func remove(_ res: Res, _ namespace: String?, _ name: String) -> JSONValue? {
        guard let removed = objects[res]?.removeValue(forKey: Self.key(namespace, name)) else { return nil }
        if let uid = removed.value(at: "metadata.uid")?.string {
            readyAt[uid] = nil
            // Garbage collection: everything owned by the removed object goes too.
            for (otherRes, items) in objects {
                for item in items.values where Self.ownerUIDs(item).contains(uid) {
                    remove(otherRes, item.value(at: "metadata.namespace")?.string, item.value(at: "metadata.name")?.string ?? "")
                }
            }
        }
        if res == .namespaces {
            for (otherRes, items) in objects {
                for item in items.values where item.value(at: "metadata.namespace")?.string == removed.value(at: "metadata.name")?.string {
                    remove(otherRes, item.value(at: "metadata.namespace")?.string, item.value(at: "metadata.name")?.string ?? "")
                }
            }
        }
        return removed
    }

    static func ownerUIDs(_ o: JSONValue) -> [String] {
        (o.value(at: "metadata.ownerReferences")?.array ?? []).compactMap { $0["uid"]?.string }
    }

    func owned(by owner: JSONValue, _ res: Res) -> [JSONValue] {
        guard let uid = owner.value(at: "metadata.uid")?.string else { return [] }
        return all(res, namespace: owner.value(at: "metadata.namespace")?.string).filter { Self.ownerUIDs($0).contains(uid) }
    }

    static func ownerReference(_ o: JSONValue) -> JSONValue {
        ["apiVersion": o["apiVersion"] ?? "v1", "kind": o["kind"] ?? "", "name": o.value(at: "metadata.name") ?? "",
         "uid": o.value(at: "metadata.uid") ?? "", "controller": true, "blockOwnerDeletion": true]
    }

    // MARK: Randomness

    mutating func uuid() -> String {
        let hex = (0..<32).map { _ in String(rng.next() % 16, radix: 16) }.joined()
        let c = Array(hex)
        return [c[0..<8], c[8..<12], c[12..<16], c[16..<20], c[20..<32]].map { String($0) }.joined(separator: "-")
    }

    /// Like the random suffix of generated names (`-x7k2p`).
    mutating func suffix(_ length: Int = 5) -> String {
        let alphabet = Array("bcdfghjklmnpqrstvwxz2456789")
        return String((0..<length).map { _ in alphabet[Int(rng.next() % UInt64(alphabet.count))] })
    }

    mutating func random(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(rng.next() % UInt64(range.count))
    }

    static func templateHash(_ template: JSONValue) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: template.anyValue, options: [.sortedKeys])) ?? Data()
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
        let alphabet = Array("bcdfghjklmnpqrstvwxz2456789")
        return String((0..<10).map { i in alphabet[Int((hash >> (UInt64(i) * 6)) % UInt64(alphabet.count))] })
    }

    static func seed(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
        return hash
    }

    // MARK: - REST

    enum Route {
        case version
        case discovery(group: String, version: String)
        case collection(Res, namespace: String?)
        case object(Res, namespace: String?, name: String, subresource: String?)
    }

    static func route(_ path: String) throws -> Route {
        let parts = path.split(separator: "/").map(String.init)
        if parts == ["version"] { return .version }
        var group = "", version = "", rest: [String] = []
        if parts.first == "api", parts.count >= 2 {
            version = parts[1]; rest = Array(parts.dropFirst(2))
        } else if parts.first == "apis", parts.count >= 3 {
            group = parts[1]; version = parts[2]; rest = Array(parts.dropFirst(3))
        } else {
            throw notFound("the server could not find the requested resource")
        }
        if rest.isEmpty { return .discovery(group: group, version: version) }
        var namespace: String?
        if rest[0] == "namespaces", rest.count >= 3 {
            namespace = rest[1]
            rest.removeFirst(2)
        }
        let res = Res(group: group, plural: rest[0])
        if rest.count == 1 { return .collection(res, namespace: namespace) }
        return .object(res, namespace: namespace, name: rest[1], subresource: rest.count > 2 ? rest[2] : nil)
    }

    static func notFound(_ message: String) -> KubeError { .api(status: 404, reason: "NotFound", message: message) }

    mutating func handle(_ method: KubeClient.Method, path: String, query: [String: String], body: Data?,
                         contentType: String, now: Date) throws -> Data {
        reconcile(now: now, initial: false)
        let dryRun = query["dryRun"] != nil
        switch try Self.route(path) {
        case .version:
            let version: JSONValue = [
                "major": "1", "minor": "34", "gitVersion": "v1.34.2", "gitCommit": "demo", "goVersion": "go1.24.9",
                "platform": "linux/arm64", "buildDate": "2026-10-28T12:00:00Z",
            ]
            return try version.jsonData()

        case .discovery(let group, let version):
            let kinds = ResourceKind.builtin.filter { $0.group == group }
            guard !kinds.isEmpty else { throw Self.notFound("the server could not find the requested resource") }
            let resources: [JSONValue] = kinds.map {
                ["name": .string($0.plural), "kind": .string($0.kind), "namespaced": .bool($0.namespaced),
                 "verbs": ["create", "delete", "get", "list", "patch", "update", "watch"]]
            }
            let list: JSONValue = ["kind": "APIResourceList", "groupVersion": .string(group.isEmpty ? version : "\(group)/\(version)"),
                                   "resources": .array(resources)]
            return try list.jsonData()

        case .collection(let res, let namespace):
            switch method {
            case .get:
                return try list(res, namespace: namespace, query: query, now: now).jsonData()
            case .post:
                return try create(res, namespace: namespace, body: body, dryRun: dryRun, now: now).jsonData()
            default:
                throw KubeError.api(status: 405, reason: "MethodNotAllowed", message: "method not allowed")
            }

        case .object(let res, let namespace, let name, let subresource):
            if let subresource {
                guard res == .pods, subresource == "log", method == .get else {
                    throw KubeError.api(status: 400, reason: "BadRequest",
                                        message: "\(subresource) is not available in the demo cluster")
                }
                let tail = query["tailLines"].flatMap(Int.init)
                return Data(try logs(pod: name, namespace: namespace ?? "default", container: query["container"],
                                     tail: tail, now: now).utf8)
            }
            switch method {
            case .get:
                guard let o = get(res, namespace, name) else { throw Self.notFound("\(res.plural) \"\(name)\" not found") }
                return try materialized(o, now: now).jsonData()
            case .put:
                return try replace(res, namespace: namespace, name: name, body: body, dryRun: dryRun, now: now).jsonData()
            case .patch:
                return try patch(res, namespace: namespace, name: name, body: body, contentType: contentType,
                                 dryRun: dryRun, now: now).jsonData()
            case .delete:
                guard let o = get(res, namespace, name) else { throw Self.notFound("\(res.plural) \"\(name)\" not found") }
                if !dryRun {
                    if res == .pods { event(for: o, reason: "Killing", message: "Stopping container \(Self.containerNames(o).first ?? name)", now: now) }
                    remove(res, namespace, name)
                    reconcile(now: now, initial: false)
                }
                return try o.jsonData()
            case .post:
                throw KubeError.api(status: 405, reason: "MethodNotAllowed", message: "method not allowed")
            }
        }
    }

    // MARK: List

    func list(_ res: Res, namespace: String?, query: [String: String], now: Date) throws -> JSONValue {
        let items: [JSONValue]
        if res.group == "metrics.k8s.io" {
            items = res.plural == "pods" ? podMetrics(namespace: namespace, now: now) : nodeMetrics(now: now)
        } else {
            guard let kind = Self.resourceKind(res) else {
                throw Self.notFound("the server could not find the requested resource (\(res.plural).\(res.group))")
            }
            items = all(res, namespace: kind.namespaced ? namespace : nil)
                .filter { Self.matches(labels: $0, query["labelSelector"]) && Self.matches(fields: $0, query["fieldSelector"]) }
                .map { materialized($0, now: now) }
        }
        let kindName = Self.resourceKind(res)?.kind ?? (res.plural == "pods" ? "PodMetrics" : "NodeMetrics")
        return ["kind": .string(kindName + "List"), "apiVersion": "v1",
                "metadata": ["resourceVersion": .string(String(resourceVersion))], "items": .array(items)]
    }

    static func matches(labels object: JSONValue, _ selector: String?) -> Bool {
        guard let selector, !selector.isEmpty else { return true }
        let labels = object.value(at: "metadata.labels")?.stringMap ?? [:]
        return selector.split(separator: ",").allSatisfy { term in
            let t = term.trimmingCharacters(in: .whitespaces)
            if let r = t.range(of: "!=") { return labels[String(t[..<r.lowerBound])] != String(t[r.upperBound...]) }
            if let r = t.range(of: "==") ?? t.range(of: "=") { return labels[String(t[..<r.lowerBound])] == String(t[r.upperBound...]) }
            if t.hasPrefix("!") { return labels[String(t.dropFirst())] == nil }
            return labels[t] != nil
        }
    }

    static func matches(fields object: JSONValue, _ selector: String?) -> Bool {
        guard let selector, !selector.isEmpty else { return true }
        return selector.split(separator: ",").allSatisfy { term in
            let negate = term.contains("!=")
            let parts = term.components(separatedBy: negate ? "!=" : "=").filter { !$0.isEmpty }
            guard parts.count == 2 else { return true }
            let value = object.value(at: parts[0])?.string ?? ""
            return negate ? value != parts[1] : value == parts[1]
        }
    }

    // MARK: Writes

    private static func decode(_ body: Data?) throws -> JSONValue {
        guard let body, let value = try? JSONValue(jsonData: body), case .object = value else {
            throw KubeError.api(status: 400, reason: "BadRequest", message: "the request body is not a JSON object")
        }
        return value
    }

    mutating func create(_ res: Res, namespace: String?, body: Data?, dryRun: Bool, now: Date) throws -> JSONValue {
        guard let kind = Self.resourceKind(res) else { throw Self.notFound("the server could not find the requested resource") }
        var o = try Self.decode(body)
        o["apiVersion"] = .string(kind.apiVersion)
        o["kind"] = .string(kind.kind)
        if kind.namespaced {
            let ns = namespace ?? o.value(at: "metadata.namespace")?.string ?? "default"
            guard get(.namespaces, nil, ns) != nil else { throw Self.notFound("namespaces \"\(ns)\" not found") }
            o.set(.string(ns), at: ["metadata", "namespace"])
        }
        if o.value(at: "metadata.name")?.string?.isEmpty ?? true {
            guard let prefix = o.value(at: "metadata.generateName")?.string else {
                throw KubeError.api(status: 422, reason: "Invalid", message: "metadata.name: Required value")
            }
            o.set(.string(prefix + suffix()), at: ["metadata", "name"])
        }
        let name = o.value(at: "metadata.name")?.string ?? ""
        let ns = o.value(at: "metadata.namespace")?.string
        if get(res, ns, name) != nil {
            throw KubeError.api(status: 409, reason: "AlreadyExists", message: "\(res.plural) \"\(name)\" already exists")
        }
        for field in ["uid", "resourceVersion", "creationTimestamp"] { o.set(nil, at: ["metadata", field]) }
        o.set(1, at: ["metadata", "generation"])
        if dryRun {
            o.set(.string(uuid()), at: ["metadata", "uid"])
            o.set(.string(now.kubeString), at: ["metadata", "creationTimestamp"])
            return o
        }
        let stored = put(o, now: now)
        reconcile(now: now, initial: false)
        return materialized(get(res, ns, name) ?? stored, now: now)
    }

    mutating func replace(_ res: Res, namespace: String?, name: String, body: Data?, dryRun: Bool, now: Date) throws -> JSONValue {
        guard let existing = get(res, namespace, name) else { throw Self.notFound("\(res.plural) \"\(name)\" not found") }
        var o = try Self.decode(body)
        return try store(o: &o, replacing: existing, res: res, dryRun: dryRun, now: now)
    }

    mutating func patch(_ res: Res, namespace: String?, name: String, body: Data?, contentType: String,
                        dryRun: Bool, now: Date) throws -> JSONValue {
        let patch = try Self.decode(body)
        guard let existing = get(res, namespace, name) else {
            if contentType.contains("apply-patch") {  // server-side apply creates missing objects
                return try create(res, namespace: namespace, body: body, dryRun: dryRun, now: now)
            }
            throw Self.notFound("\(res.plural) \"\(name)\" not found")
        }
        var o = Self.mergePatch(existing, patch)
        return try store(o: &o, replacing: existing, res: res, dryRun: dryRun, now: now)
    }

    private mutating func store(o: inout JSONValue, replacing existing: JSONValue, res: Res, dryRun: Bool, now: Date) throws -> JSONValue {
        for field in ["uid", "creationTimestamp", "name", "namespace", "ownerReferences"] {
            o.set(existing.value(at: "metadata.\(field)"), at: ["metadata", field])
        }
        o["apiVersion"] = existing["apiVersion"]
        o["kind"] = existing["kind"]
        if res != .pods, o["status"] == nil { o["status"] = existing["status"] }
        let generation = existing.value(at: "metadata.generation")?.int ?? 1
        o.set(.int(Int64(o["spec"] == existing["spec"] ? generation : generation + 1)), at: ["metadata", "generation"])
        if dryRun { return o }
        let stored = put(o, now: now)
        reconcile(now: now, initial: false)
        return materialized(get(res, o.value(at: "metadata.namespace")?.string, o.value(at: "metadata.name")?.string ?? "") ?? stored, now: now)
    }

    /// JSON merge patch (RFC 7386).
    static func mergePatch(_ target: JSONValue, _ patch: JSONValue) -> JSONValue {
        guard case .object(let p) = patch else { return patch }
        var result = target.object ?? [:]
        for (key, value) in p {
            if value == .null { result[key] = nil } else { result[key] = mergePatch(result[key] ?? .null, value) }
        }
        return .object(result)
    }

    // MARK: - Controllers

    mutating func reconcile(now: Date, initial: Bool) {
        reconcileDeployments(now: now, initial: initial)
        for rs in all(.replicaSets) { reconcileReplicaSet(rs, now: now, initial: initial) }
        for d in all(.deployments) { updateDeploymentStatus(d, now: now) }
        for sts in all(.statefulSets) { reconcileStatefulSet(sts, now: now, initial: initial) }
        for ds in all(.daemonSets) { reconcileDaemonSet(ds, now: now, initial: initial) }
        for job in all(.jobs) { reconcileJob(job, now: now, initial: initial) }
        reconcileEndpoints(now: now)
    }

    private mutating func reconcileDeployments(now: Date, initial: Bool) {
        for d in all(.deployments) {
            guard let template = d.value(at: "spec.template") else { continue }
            let name = d.value(at: "metadata.name")?.string ?? ""
            let ns = d.value(at: "metadata.namespace")?.string
            let replicas = d.value(at: "spec.replicas")?.int ?? 1
            let hash = Self.templateHash(template)
            let current = "\(name)-\(hash)"
            let replicaSets = owned(by: d, .replicaSets)
            if !replicaSets.contains(where: { $0.value(at: "metadata.name")?.string == current }) {
                let revision = (replicaSets.compactMap { $0["metadata"]?["annotations"]?["deployment.kubernetes.io/revision"]?.int }.max() ?? 0) + 1
                var podTemplate = template
                podTemplate.set(.string(hash), at: ["metadata", "labels", "pod-template-hash"])
                var selector = d.value(at: "spec.selector") ?? ["matchLabels": template.value(at: "metadata.labels") ?? [:]]
                selector.set(.string(hash), at: ["matchLabels", "pod-template-hash"])
                put([
                    "apiVersion": "apps/v1", "kind": "ReplicaSet",
                    "metadata": [
                        "name": .string(current), "namespace": .string(ns ?? "default"),
                        "labels": podTemplate.value(at: "metadata.labels") ?? [:],
                        "annotations": ["deployment.kubernetes.io/revision": .string(String(revision)),
                                        "deployment.kubernetes.io/desired-replicas": .string(String(replicas)),
                                        "deployment.kubernetes.io/max-replicas": .string(String(replicas + 1))],
                        "ownerReferences": [Self.ownerReference(d)],
                        "creationTimestamp": initial ? (d.value(at: "metadata.creationTimestamp") ?? .null) : .string(now.kubeString),
                    ],
                    "spec": ["replicas": .int(Int64(replicas)), "selector": selector, "template": podTemplate],
                ], now: now)
                if !initial {
                    event(for: d, reason: "ScalingReplicaSet", message: "Scaled up replica set \(current) from 0 to \(replicas)",
                          component: "deployment-controller", now: now)
                }
            }
            for var rs in owned(by: d, .replicaSets) {
                let rsName = rs.value(at: "metadata.name")?.string ?? ""
                let want = rsName == current ? replicas : 0
                let have = rs.value(at: "spec.replicas")?.int ?? 0
                guard have != want else { continue }
                rs.set(.int(Int64(want)), at: ["spec", "replicas"])
                put(rs, now: now)
                if !initial {
                    event(for: d, reason: "ScalingReplicaSet",
                          message: "Scaled \(want > have ? "up" : "down") replica set \(rsName) from \(have) to \(want)",
                          component: "deployment-controller", now: now)
                }
            }
        }
    }

    private mutating func reconcileReplicaSet(_ rs: JSONValue, now: Date, initial: Bool) {
        let want = rs.value(at: "spec.replicas")?.int ?? 0
        let pods = owned(by: rs, .pods).sorted { created($0) < created($1) }
        if pods.count < want, let template = rs.value(at: "spec.template") {
            let name = rs.value(at: "metadata.name")?.string ?? ""
            for _ in pods.count..<want {
                let podName = "\(name)-\(suffix())"
                createPod(podName, template: template, owner: rs, now: now, initial: initial)
                if !initial {
                    event(for: rs, reason: "SuccessfulCreate", message: "Created pod: \(podName)", component: "replicaset-controller", now: now)
                }
            }
        } else if pods.count > want {
            for pod in pods.suffix(pods.count - want) {
                let podName = pod.value(at: "metadata.name")?.string ?? ""
                remove(.pods, pod.value(at: "metadata.namespace")?.string, podName)
                event(for: rs, reason: "SuccessfulDelete", message: "Deleted pod: \(podName)", component: "replicaset-controller", now: now)
            }
        }
        let current = owned(by: rs, .pods)
        let ready = current.filter { podState($0, now: now).ready }.count
        var updated = rs
        updated["status"] = ["replicas": .int(Int64(current.count)), "fullyLabeledReplicas": .int(Int64(current.count)),
                             "readyReplicas": .int(Int64(ready)), "availableReplicas": .int(Int64(ready)),
                             "observedGeneration": rs.value(at: "metadata.generation") ?? 1]
        if updated["status"] != rs["status"] { put(updated, now: now) }
    }

    private mutating func updateDeploymentStatus(_ d: JSONValue, now: Date) {
        guard let template = d.value(at: "spec.template") else { return }
        let current = "\(d.value(at: "metadata.name")?.string ?? "")-\(Self.templateHash(template))"
        var total = 0, ready = 0, updated = 0
        for rs in owned(by: d, .replicaSets) {
            for pod in owned(by: rs, .pods) {
                total += 1
                if podState(pod, now: now).ready { ready += 1 }
                if rs.value(at: "metadata.name")?.string == current { updated += 1 }
            }
        }
        let want = d.value(at: "spec.replicas")?.int ?? 1
        let available = ready >= want
        let since = d.value(at: "metadata.creationTimestamp") ?? .string(now.kubeString)
        var status: JSONValue = [
            "observedGeneration": d.value(at: "metadata.generation") ?? 1,
            "replicas": .int(Int64(total)), "updatedReplicas": .int(Int64(updated)),
            "readyReplicas": .int(Int64(ready)), "availableReplicas": .int(Int64(ready)),
            "conditions": [
                ["type": "Available", "status": available ? "True" : "False",
                 "reason": available ? "MinimumReplicasAvailable" : "MinimumReplicasUnavailable",
                 "message": available ? "Deployment has minimum availability." : "Deployment does not have minimum availability.",
                 "lastTransitionTime": since, "lastUpdateTime": since],
                ["type": "Progressing", "status": "True", "reason": "NewReplicaSetAvailable",
                 "message": .string("ReplicaSet \"\(current)\" has successfully progressed."),
                 "lastTransitionTime": since, "lastUpdateTime": since],
            ],
        ]
        if total > ready { status["unavailableReplicas"] = .int(Int64(total - ready)) }
        if d["status"]?["replicas"] != status["replicas"] || d["status"]?["readyReplicas"] != status["readyReplicas"]
            || d["status"]?["updatedReplicas"] != status["updatedReplicas"] || d["status"]?["observedGeneration"] != status["observedGeneration"] {
            var updatedDeployment = d
            updatedDeployment["status"] = status
            put(updatedDeployment, now: now)
        }
    }

    private mutating func reconcileStatefulSet(_ sts: JSONValue, now: Date, initial: Bool) {
        let name = sts.value(at: "metadata.name")?.string ?? ""
        let ns = sts.value(at: "metadata.namespace")?.string ?? "default"
        let want = sts.value(at: "spec.replicas")?.int ?? 1
        guard let template = sts.value(at: "spec.template") else { return }
        for i in 0..<want where get(.pods, ns, "\(name)-\(i)") == nil {
            for claim in sts.value(at: "spec.volumeClaimTemplates")?.array ?? [] {
                let claimName = "\(claim.value(at: "metadata.name")?.string ?? "data")-\(name)-\(i)"
                if get(.pvcs, ns, claimName) == nil { createVolume(claim: claim, name: claimName, namespace: ns, owner: sts, now: now) }
            }
            var podTemplate = template
            podTemplate.set(.string("\(name)-\(i)"), at: ["metadata", "labels", "statefulset.kubernetes.io/pod-name"])
            createPod("\(name)-\(i)", template: podTemplate, owner: sts, now: now, initial: initial)
            if !initial {
                event(for: sts, reason: "SuccessfulCreate", message: "create Pod \(name)-\(i) in StatefulSet \(name) successful",
                      component: "statefulset-controller", now: now)
            }
        }
        for pod in owned(by: sts, .pods) {
            let podName = pod.value(at: "metadata.name")?.string ?? ""
            if let index = Int(podName.split(separator: "-").last ?? ""), index >= want {
                remove(.pods, ns, podName)
                event(for: sts, reason: "SuccessfulDelete", message: "delete Pod \(podName) in StatefulSet \(name) successful",
                      component: "statefulset-controller", now: now)
            }
        }
        let pods = owned(by: sts, .pods)
        let ready = pods.filter { podState($0, now: now).ready }.count
        let status: JSONValue = ["replicas": .int(Int64(pods.count)), "readyReplicas": .int(Int64(ready)),
                                 "currentReplicas": .int(Int64(pods.count)), "updatedReplicas": .int(Int64(pods.count)),
                                 "availableReplicas": .int(Int64(ready)), "observedGeneration": sts.value(at: "metadata.generation") ?? 1]
        if sts["status"] != status {
            var updated = sts
            updated["status"] = status
            put(updated, now: now)
        }
    }

    private mutating func createVolume(claim: JSONValue, name: String, namespace: String, owner: JSONValue, now: Date) {
        let size = claim.value(at: "spec.resources.requests.storage")?.string ?? "1Gi"
        let pvName = "pvc-\(uuid())"
        let storageClass = claim.value(at: "spec.storageClassName")?.string ?? "local-path"
        let labels = owner.value(at: "spec.selector.matchLabels") ?? [:]
        put([
            "apiVersion": "v1", "kind": "PersistentVolumeClaim",
            "metadata": ["name": .string(name), "namespace": .string(namespace), "labels": labels,
                         "creationTimestamp": owner.value(at: "metadata.creationTimestamp") ?? .string(now.kubeString)],
            "spec": ["accessModes": ["ReadWriteOnce"], "resources": ["requests": ["storage": .string(size)]],
                     "storageClassName": .string(storageClass), "volumeName": .string(pvName), "volumeMode": "Filesystem"],
            "status": ["phase": "Bound", "accessModes": ["ReadWriteOnce"], "capacity": ["storage": .string(size)]],
        ], now: now)
        put([
            "apiVersion": "v1", "kind": "PersistentVolume",
            "metadata": ["name": .string(pvName), "creationTimestamp": owner.value(at: "metadata.creationTimestamp") ?? .string(now.kubeString)],
            "spec": ["accessModes": ["ReadWriteOnce"], "capacity": ["storage": .string(size)],
                     "claimRef": ["kind": "PersistentVolumeClaim", "name": .string(name), "namespace": .string(namespace)],
                     "persistentVolumeReclaimPolicy": "Delete", "storageClassName": .string(storageClass), "volumeMode": "Filesystem",
                     "hostPath": ["path": .string("/var/lib/rancher/k3s/storage/\(pvName)_\(namespace)_\(name)"), "type": "DirectoryOrCreate"]],
            "status": ["phase": "Bound"],
        ], now: now)
    }

    private mutating func reconcileDaemonSet(_ ds: JSONValue, now: Date, initial: Bool) {
        guard let template = ds.value(at: "spec.template") else { return }
        let tolerations = template.value(at: "spec.tolerations")?.array ?? []
        let nodes = all(.nodes).filter { Self.tolerates(tolerations, $0, ignoreUnschedulable: true) }
        let pods = owned(by: ds, .pods)
        for node in nodes {
            let nodeName = node.value(at: "metadata.name")?.string ?? ""
            if !pods.contains(where: { $0.value(at: "spec.nodeName")?.string == nodeName }) {
                createPod("\(ds.value(at: "metadata.name")?.string ?? "")-\(suffix())", template: template, owner: ds,
                          now: now, initial: initial, node: nodeName)
            }
        }
        let current = owned(by: ds, .pods)
        let ready = current.filter { podState($0, now: now).ready }.count
        let status: JSONValue = ["desiredNumberScheduled": .int(Int64(nodes.count)), "currentNumberScheduled": .int(Int64(current.count)),
                                 "updatedNumberScheduled": .int(Int64(current.count)), "numberReady": .int(Int64(ready)),
                                 "numberAvailable": .int(Int64(ready)), "numberMisscheduled": 0,
                                 "observedGeneration": ds.value(at: "metadata.generation") ?? 1]
        if ds["status"] != status {
            var updated = ds
            updated["status"] = status
            put(updated, now: now)
        }
    }

    private mutating func reconcileJob(_ job: JSONValue, now: Date, initial: Bool) {
        let pods = owned(by: job, .pods)
        if pods.isEmpty, job.value(at: "status.completionTime") == nil, let template = job.value(at: "spec.template") {
            let name = "\(job.value(at: "metadata.name")?.string ?? "")-\(suffix())"
            createPod(name, template: template, owner: job, now: now, initial: initial)
            if !initial { event(for: job, reason: "SuccessfulCreate", message: "Created pod: \(name)", component: "job-controller", now: now) }
        }
        guard let pod = owned(by: job, .pods).first else { return }
        let state = podState(pod, now: now)
        let started = pod.value(at: "metadata.creationTimestamp") ?? .string(now.kubeString)
        var status: JSONValue = ["startTime": started, "active": state.phase == "Running" || state.phase == "Pending" ? 1 : 0,
                                 "ready": state.ready ? 1 : 0, "uncountedTerminatedPods": [:]]
        if state.phase == "Succeeded", let uid = pod.value(at: "metadata.uid")?.string, let finished = readyAt[uid] {
            status["succeeded"] = 1
            status["active"] = nil
            status["completionTime"] = .string(finished.kubeString)
            status["conditions"] = [["type": "Complete", "status": "True", "lastProbeTime": .string(finished.kubeString),
                                     "lastTransitionTime": .string(finished.kubeString)]]
        }
        if job["status"] != status {
            if !initial, status["succeeded"] != nil, job["status"]?["succeeded"] == nil {
                event(for: job, reason: "Completed", message: "Job completed", component: "job-controller", now: now)
            }
            var updated = job
            updated["status"] = status
            put(updated, now: now)
        }
    }

    private mutating func reconcileEndpoints(now: Date) {
        for service in all(.services) {
            guard let selector = service.value(at: "spec.selector")?.stringMap, !selector.isEmpty else { continue }
            let ns = service.value(at: "metadata.namespace")?.string ?? "default"
            let name = service.value(at: "metadata.name")?.string ?? ""
            let pods = all(.pods, namespace: ns).filter { pod in
                let labels = pod.value(at: "metadata.labels")?.stringMap ?? [:]
                return selector.allSatisfy { labels[$0.key] == $0.value }
            }
            let readyPods = pods.filter { podState($0, now: now).ready }
            let notReady = pods.filter { !podState($0, now: now).ready && $0.value(at: "spec.nodeName") != nil }
            func address(_ pod: JSONValue) -> JSONValue {
                ["ip": pod.value(at: "status.podIP") ?? "", "nodeName": pod.value(at: "spec.nodeName") ?? .null,
                 "targetRef": ["kind": "Pod", "name": pod.value(at: "metadata.name") ?? "", "namespace": .string(ns),
                               "uid": pod.value(at: "metadata.uid") ?? ""]]
            }
            let ports: [JSONValue] = (service.value(at: "spec.ports")?.array ?? []).map { port in
                let target = port["targetPort"]?.int ?? port["port"]?.int ?? 0
                return ["name": port["name"] ?? .null, "port": .int(Int64(target)), "protocol": port["protocol"] ?? "TCP"]
            }
            var subset: JSONValue = ["ports": .array(ports)]
            if !readyPods.isEmpty { subset["addresses"] = .array(readyPods.map(address)) }
            if !notReady.isEmpty { subset["notReadyAddresses"] = .array(notReady.map(address)) }
            let subsets: JSONValue = readyPods.isEmpty && notReady.isEmpty ? [] : [subset]
            if let existing = get(.endpoints, ns, name), existing["subsets"] == subsets { continue }
            put(["apiVersion": "v1", "kind": "Endpoints",
                 "metadata": ["name": .string(name), "namespace": .string(ns), "labels": service.value(at: "metadata.labels") ?? [:],
                              "creationTimestamp": service.value(at: "metadata.creationTimestamp") ?? .string(now.kubeString)],
                 "subsets": subsets], now: now)
        }
    }

    // MARK: Pods

    private func created(_ o: JSONValue) -> Date {
        o.value(at: "metadata.creationTimestamp")?.string.flatMap(KubeDate.parse) ?? start
    }

    static func tolerates(_ tolerations: [JSONValue], _ node: JSONValue, ignoreUnschedulable: Bool = false) -> Bool {
        if !ignoreUnschedulable, node.value(at: "spec.unschedulable")?.bool == true { return false }
        let taints = (node.value(at: "spec.taints")?.array ?? []).filter { $0["effect"]?.string == "NoSchedule" }
        return taints.allSatisfy { taint in
            tolerations.contains { t in
                t["operator"]?.string == "Exists" && (t["key"] == nil || t["key"] == taint["key"]) || t["key"] == taint["key"]
            }
        }
    }

    private mutating func createPod(_ name: String, template: JSONValue, owner: JSONValue, now: Date, initial: Bool, node: String? = nil) {
        let ns = owner.value(at: "metadata.namespace")?.string ?? "default"
        var spec = template["spec"] ?? [:]
        let ownerCreated = created(owner)
        let startedAt = initial ? ownerCreated.addingTimeInterval(Double(random(5...90))) : now
        let wantsGPU = (spec["containers"]?.array ?? []).contains { $0.value(at: "resources.limits")?["nvidia.com/gpu"] != nil }
        let tolerations = spec["tolerations"]?.array ?? []
        let candidates = all(.nodes).filter { Self.tolerates(tolerations, $0) }
        let nodeName = node ?? (wantsGPU || candidates.isEmpty ? nil
            : candidates[Int(Self.seed(name) % UInt64(candidates.count))].value(at: "metadata.name")?.string)
        var status: JSONValue = ["qosClass": .string(Self.qosClass(spec))]
        if let nodeName {
            spec["nodeName"] = .string(nodeName)
            let nodeIndex = all(.nodes).firstIndex { $0.value(at: "metadata.name")?.string == nodeName } ?? 0
            let ip = "10.42.\(nodeIndex).\(random(2...250))"
            let hostIP = all(.nodes)[nodeIndex].value(at: "status.addresses")?.array?.first?["address"] ?? "10.0.0.10"
            status["podIP"] = .string(ip)
            status["podIPs"] = [["ip": .string(ip)]]
            status["hostIP"] = hostIP
            status["startTime"] = .string(startedAt.kubeString)
        }
        if spec["serviceAccountName"] == nil { spec["serviceAccountName"] = "default" }
        if spec["restartPolicy"] == nil { spec["restartPolicy"] = owner["kind"] == "Job" ? "Never" : "Always" }
        let pod = put([
            "apiVersion": "v1", "kind": "Pod",
            "metadata": ["name": .string(name), "namespace": .string(ns),
                         "labels": template.value(at: "metadata.labels") ?? [:],
                         "annotations": template.value(at: "metadata.annotations") ?? .null,
                         "ownerReferences": [Self.ownerReference(owner)],
                         "creationTimestamp": .string(startedAt.kubeString)],
            "spec": spec, "status": status,
        ], now: now)
        let uid = pod.value(at: "metadata.uid")?.string ?? ""
        if owner["kind"] == "Job" {
            readyAt[uid] = startedAt.addingTimeInterval(Double(initial ? random(30...140) : random(6...12)))
        } else {
            readyAt[uid] = initial ? startedAt.addingTimeInterval(Double(random(4...20))) : now.addingTimeInterval(Double(random(2...5)))
        }
        guard !initial, let nodeName else { return }
        let image = spec["containers"]?[0]?["image"]?.string ?? ""
        event(for: pod, reason: "Scheduled", message: "Successfully assigned \(ns)/\(name) to \(nodeName)", component: "default-scheduler", now: now)
        event(for: pod, reason: "Pulled", message: "Container image \"\(image)\" already present on machine", component: "kubelet", now: now)
        event(for: pod, reason: "Created", message: "Created container: \(Self.containerNames(pod).first ?? name)", component: "kubelet", now: now)
        event(for: pod, reason: "Started", message: "Started container \(Self.containerNames(pod).first ?? name)", component: "kubelet", now: now)
    }

    static func containerNames(_ pod: JSONValue) -> [String] {
        (pod.value(at: "spec.containers")?.array ?? []).compactMap { $0["name"]?.string }
    }

    static func qosClass(_ spec: JSONValue) -> String {
        let containers = spec["containers"]?.array ?? []
        if containers.allSatisfy({ $0.value(at: "resources.limits.cpu") != nil && $0.value(at: "resources.limits.memory") != nil
            && $0.value(at: "resources.requests") == $0.value(at: "resources.limits") }) { return "Guaranteed" }
        return containers.contains { $0.value(at: "resources.requests") != nil || $0.value(at: "resources.limits") != nil } ? "Burstable" : "BestEffort"
    }

    static func appName(_ pod: JSONValue) -> String {
        let labels = pod.value(at: "metadata.labels")?.stringMap ?? [:]
        return labels["app.kubernetes.io/name"] ?? labels["app"] ?? labels["k8s-app"] ?? pod.value(at: "metadata.name")?.string ?? ""
    }

    struct PodState {
        var phase: String
        var ready: Bool
        var unschedulable = false
        var crashLooping = false
    }

    func podState(_ pod: JSONValue, now: Date) -> PodState {
        guard pod.value(at: "spec.nodeName") != nil else { return PodState(phase: "Pending", ready: false, unschedulable: true) }
        let uid = pod.value(at: "metadata.uid")?.string ?? ""
        let at = readyAt[uid] ?? start
        if pod.value(at: "metadata.ownerReferences")?[0]?["kind"]?.string == "Job" {
            return now < at ? PodState(phase: "Running", ready: true) : PodState(phase: "Succeeded", ready: false)
        }
        if DemoFixtures.crashingApps.contains(Self.appName(pod)) {
            return PodState(phase: "Running", ready: false, crashLooping: true)
        }
        return now < at ? PodState(phase: "Pending", ready: false) : PodState(phase: "Running", ready: true)
    }

    /// The object as returned by the API: pods get their current status.
    func materialized(_ o: JSONValue, now: Date) -> JSONValue {
        guard o["kind"] == "Pod" else { return o }
        var pod = o
        let state = podState(o, now: now)
        let uid = o.value(at: "metadata.uid")?.string ?? ""
        let created = self.created(o)
        let at = readyAt[uid] ?? start
        let createdString: JSONValue = .string(created.kubeString)
        pod.set(.string(state.phase), at: ["status", "phase"])
        if state.unschedulable {
            pod.set([["type": "PodScheduled", "status": "False", "reason": "Unschedulable", "lastTransitionTime": createdString,
                      "message": "0/3 nodes are available: 1 node(s) had untolerated taint {node-role.kubernetes.io/control-plane: }, 2 Insufficient nvidia.com/gpu. preemption: 0/3 nodes are available: 3 No preemption victims found for incoming pod."]],
                    at: ["status", "conditions"])
            return pod
        }
        let seed = Self.seed(o.value(at: "metadata.name")?.string ?? "")
        let containers: [JSONValue] = (o.value(at: "spec.containers")?.array ?? []).map { c in
            var s: JSONValue = ["name": c["name"] ?? "", "image": c["image"] ?? "",
                                "imageID": .string("docker.io/library/\(c["image"]?.string ?? "")@sha256:\(String(format: "%016llx", seed))"),
                                "containerID": .string("containerd://\(String(format: "%016llx%016llx", seed, seed &* 31))"),
                                "started": .bool(state.phase == "Running"), "ready": .bool(state.ready), "restartCount": 0]
            switch state.phase {
            case "Succeeded":
                s["state"] = ["terminated": ["exitCode": 0, "reason": "Completed", "startedAt": createdString, "finishedAt": .string(at.kubeString)]]
            case "Pending":
                s["state"] = ["waiting": ["reason": "ContainerCreating"]]
            default:
                if state.crashLooping {
                    let restarts = 6 + Int(now.timeIntervalSince(start) / 150)
                    s["restartCount"] = .int(Int64(restarts))
                    s["state"] = ["waiting": ["reason": "CrashLoopBackOff",
                                              "message": .string("back-off 5m0s restarting failed container=\(c["name"]?.string ?? "") pod=\(o.value(at: "metadata.name")?.string ?? "")_\(o.value(at: "metadata.namespace")?.string ?? "")(\(uid))")]]
                    s["lastState"] = ["terminated": ["exitCode": 1, "reason": "Error",
                                                     "startedAt": .string(now.addingTimeInterval(-95).kubeString),
                                                     "finishedAt": .string(now.addingTimeInterval(-88).kubeString)]]
                } else {
                    let restarts = seed % 9 == 0 ? Int(seed % 3) + 1 : 0
                    s["restartCount"] = .int(Int64(restarts))
                    s["state"] = ["running": ["startedAt": .string(at.kubeString)]]
                }
            }
            return s
        }
        pod.set(.array(containers), at: ["status", "containerStatuses"])
        let readyString: JSONValue = state.ready ? "True" : "False"
        let transition: JSONValue = .string((state.phase == "Pending" ? created : at).kubeString)
        pod.set([
            ["type": "PodReadyToStartContainers", "status": state.phase == "Pending" ? "False" : "True", "lastTransitionTime": transition],
            ["type": "Initialized", "status": "True", "lastTransitionTime": createdString],
            ["type": "Ready", "status": readyString, "lastTransitionTime": transition],
            ["type": "ContainersReady", "status": readyString, "lastTransitionTime": transition],
            ["type": "PodScheduled", "status": "True", "lastTransitionTime": createdString],
        ], at: ["status", "conditions"])
        return pod
    }

    // MARK: Events

    mutating func event(for object: JSONValue, reason: String, message: String, type: String = "Normal",
                        component: String = "kubelet", count: Int = 1, first: Date? = nil, now: Date) {
        let name = object.value(at: "metadata.name")?.string ?? ""
        let ns = object.value(at: "metadata.namespace")?.string ?? "default"
        let firstSeen = first ?? now
        put([
            "apiVersion": "v1", "kind": "Event",
            "metadata": ["name": .string("\(name).\(String(format: "%016llx", rng.next()))"), "namespace": .string(ns),
                         "creationTimestamp": .string(firstSeen.kubeString)],
            "involvedObject": ["kind": object["kind"] ?? "", "name": .string(name), "namespace": .string(ns),
                               "uid": object.value(at: "metadata.uid") ?? "", "apiVersion": object["apiVersion"] ?? "v1"],
            "reason": .string(reason), "message": .string(message), "type": .string(type), "count": .int(Int64(count)),
            "firstTimestamp": .string(firstSeen.kubeString), "lastTimestamp": .string(now.kubeString),
            "source": ["component": .string(component)], "reportingComponent": .string(component),
        ], now: now)
        // Like the API server's event TTL: keep the newest 400.
        if let events = objects[.events], events.count > 400 {
            let oldest = events.sorted { ($0.value.value(at: "lastTimestamp")?.string ?? "") < ($1.value.value(at: "lastTimestamp")?.string ?? "") }
            for (key, _) in oldest.prefix(events.count - 400) { objects[.events]?[key] = nil }
        }
    }

    // MARK: Metrics

    private func usage(_ pod: JSONValue, container: JSONValue, now: Date) -> (cpu: Double, memory: Double) {
        let seed = Self.seed("\(pod.value(at: "metadata.name")?.string ?? "")/\(container["name"]?.string ?? "")")
        let phase = Double(seed % 1000) / 1000 * 2 * .pi
        let t = now.timeIntervalSince1970
        let wave = (sin(t / 37 + phase) + 1) / 2
        let slow = (sin(t / 300 + phase * 2) + 1) / 2
        let cpuRequest = container.value(at: "resources.requests.cpu")?.string.flatMap(Quantity.parse) ?? 0.05
        let memRequest = container.value(at: "resources.requests.memory")?.string.flatMap(Quantity.parse) ?? 64 * 1_048_576
        return (cpuRequest * (0.15 + 0.6 * wave * (0.5 + slow)), memRequest * (0.45 + 0.35 * slow))
    }

    func podMetrics(namespace: String?, now: Date) -> [JSONValue] {
        all(.pods, namespace: namespace).filter { podState($0, now: now).phase == "Running" && !podState($0, now: now).crashLooping }.map { pod in
            let containers: [JSONValue] = (pod.value(at: "spec.containers")?.array ?? []).map { c in
                let u = usage(pod, container: c, now: now)
                return ["name": c["name"] ?? "", "usage": ["cpu": .string("\(Int(u.cpu * 1e9))n"), "memory": .string("\(Int(u.memory / 1024))Ki")]]
            }
            return ["kind": "PodMetrics", "apiVersion": "metrics.k8s.io/v1beta1",
                    "metadata": ["name": pod.value(at: "metadata.name") ?? "", "namespace": pod.value(at: "metadata.namespace") ?? "",
                                 "creationTimestamp": .string(now.kubeString)],
                    "timestamp": .string(now.kubeString), "window": "15s", "containers": .array(containers)]
        }
    }

    func nodeMetrics(now: Date) -> [JSONValue] {
        all(.nodes).map { node in
            let name = node.value(at: "metadata.name")?.string ?? ""
            var cpu = 0.18, memory = 1.1 * 1_073_741_824  // kubelet, containerd, OS
            for pod in all(.pods) where pod.value(at: "spec.nodeName")?.string == name && podState(pod, now: now).phase == "Running" {
                for c in pod.value(at: "spec.containers")?.array ?? [] {
                    let u = usage(pod, container: c, now: now)
                    cpu += u.cpu
                    memory += u.memory
                }
            }
            return ["kind": "NodeMetrics", "apiVersion": "metrics.k8s.io/v1beta1",
                    "metadata": ["name": .string(name), "creationTimestamp": .string(now.kubeString)],
                    "timestamp": .string(now.kubeString), "window": "20s",
                    "usage": ["cpu": .string("\(Int(cpu * 1e9))n"), "memory": .string("\(Int(memory / 1024))Ki")]]
        }
    }

    // MARK: Logs

    private func logContext(pod name: String, namespace: String, container: String?) throws -> (pod: JSONValue, container: String, app: String) {
        guard let pod = get(.pods, namespace, name) else { throw Self.notFound("pods \"\(name)\" not found") }
        let names = Self.containerNames(pod)
        let c = container ?? names.first ?? ""
        guard names.contains(c) else {
            throw KubeError.api(status: 400, reason: "BadRequest", message: "container \(c) is not valid for pod \(name)")
        }
        return (pod, c, Self.appName(pod))
    }

    func logs(pod name: String, namespace: String, container: String?, tail: Int?, now: Date) throws -> String {
        let (pod, container, app) = try logContext(pod: name, namespace: namespace, container: container)
        let state = podState(pod, now: now)
        if state.unschedulable || state.phase == "Pending" { return "" }
        let started = readyAt[pod.value(at: "metadata.uid")?.string ?? ""] ?? start
        if state.crashLooping { return DemoLogs.crash(app: app, at: now.addingTimeInterval(-95)).joined(separator: "\n") + "\n" }
        let end = state.phase == "Succeeded" ? started : now
        let begin = state.phase == "Succeeded" ? created(pod) : started
        let interval = DemoLogs.interval(app: app)
        let total = max(1, Int(end.timeIntervalSince(begin) / interval))
        let count = min(tail ?? 1000, total, 1000)
        let seed = Self.seed("\(name)/\(container)")
        var lines = (total - count..<total).map { i in
            DemoLogs.line(app: app, container: container, index: i, seed: seed, at: begin.addingTimeInterval(Double(i) * interval))
        }
        if total <= count { lines.insert(contentsOf: DemoLogs.startup(app: app, at: begin), at: 0) }
        if state.phase == "Succeeded" { lines.append(contentsOf: DemoLogs.finish(app: app, at: end)) }
        return lines.joined(separator: "\n") + "\n"
    }

    func liveLogLine(pod name: String, namespace: String, container: String?, now: Date) throws -> String? {
        let (pod, container, app) = try logContext(pod: name, namespace: namespace, container: container)
        guard podState(pod, now: now).phase == "Running", !podState(pod, now: now).crashLooping else { return nil }
        let index = Int(now.timeIntervalSince1970 * 10)
        return DemoLogs.line(app: app, container: container, index: index, seed: Self.seed("\(name)/\(container)"), at: now)
    }
}

/// Small deterministic PRNG (the demo should look the same on every launch).
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension Date {
    /// RFC 3339 like the API server writes it.
    var kubeString: String { formatted(.iso8601) }
}
