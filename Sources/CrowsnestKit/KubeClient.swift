import AsyncHTTPClient
import Foundation
import NIOCore
import NIOPosix
import NIOFoundationCompat
import NIOHTTP1
import NIOSSL

/// Talks to one Kubernetes API server with the credentials of one kubeconfig context.
///
/// Instances own an `HTTPClient` and live for the lifetime of the app
/// (see ``KubeClientPool``), because the HTTP client must be shut down
/// explicitly before it is released.
public actor KubeClient {
    public nonisolated let config: ConnectionConfig
    nonisolated let http: HTTPClient
    /// TLS context for streaming connections (exec, port-forward), which bypass `HTTPClient`.
    nonisolated let sslContext: NIOSSLContext
    private var execCredential: ExecCredential?
    var discoveredKinds: [String: ResourceKind] = [:]
    /// Set for the built-in demo cluster: requests are answered in memory instead of over the network.
    nonisolated let demo: DemoCluster?

    public init(config: ConnectionConfig) throws {
        self.config = config
        demo = config.isDemo ? DemoCluster() : nil
        var tls = TLSConfiguration.makeClientConfiguration()
        do {
            if config.insecureSkipTLSVerify {
                tls.certificateVerification = .none
            } else if let ca = config.caPEM {
                tls.trustRoots = .certificates(try NIOSSLCertificate.fromPEMBytes(Array(ca)))
            }
            if let cert = config.clientCertificatePEM, let key = config.clientKeyPEM {
                tls.certificateChain = try NIOSSLCertificate.fromPEMBytes(Array(cert)).map { .certificate($0) }
                tls.privateKey = .privateKey(try NIOSSLPrivateKey(bytes: Array(key), format: .pem))
            }
        } catch {
            throw KubeError.invalidConfig("Could not read certificate/key: \(error)")
        }
        do {
            sslContext = try NIOSSLContext(configuration: tls)
        } catch {
            throw KubeError.invalidConfig("Invalid TLS configuration: \(error)")
        }
        var configuration = HTTPClient.Configuration(tlsConfiguration: tls)
        configuration.timeout = .init(connect: .seconds(10))
        configuration.redirectConfiguration = .disallow
        configuration.decompression = .enabled(limit: .none)
        // NIO event loops (not Network.framework) so that BoringSSL handles PEM client certificates.
        http = HTTPClient(eventLoopGroupProvider: .shared(MultiThreadedEventLoopGroup.singleton), configuration: configuration)
    }

    public func shutdown() async {
        try? await http.shutdown()
    }

    // MARK: - Low level

    public enum Method: Sendable {
        case get, post, put, patch, delete
        var http: HTTPMethod {
            switch self {
            case .get: .GET
            case .post: .POST
            case .put: .PUT
            case .patch: .PATCH
            case .delete: .DELETE
            }
        }
    }

    func url(path: String, query: [String: String]) -> String {
        Self.buildURL(server: config.server, path: path, query: query)
    }

    static func buildURL(server: URL, path: String, query: [String: String]) -> String {
        var base = server.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        var result = base + path
        if !query.isEmpty {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            result += "?" + query.sorted { $0.key < $1.key }.map { key, value in
                "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
            }.joined(separator: "&")
        }
        return result
    }

    func authorization(forceRefresh: Bool = false) async throws -> String? {
        switch config.auth {
        case .none:
            return nil
        case .bearer(let token):
            return "Bearer \(token)"
        case .tokenFile(let path):
            let token = try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            return "Bearer \(token)"
        case .basic(let user, let password):
            return "Basic \(Data("\(user):\(password)".utf8).base64EncodedString())"
        case .exec(let exec):
            #if os(macOS)
            if forceRefresh || !(execCredential?.isValid() ?? false) {
                execCredential = try await ExecCredentialRunner.run(exec, server: config.server)
            }
            guard let token = execCredential?.token else {
                throw KubeError.unsupported("exec plugins that return a client certificate instead of a token")
            }
            return "Bearer \(token)"
            #else
            throw KubeError.unsupported("exec auth plugins ('\(exec.command)') are not available on this device")
            #endif
        }
    }

    func makeRequest(_ method: Method, path: String, query: [String: String] = [:], body: Data? = nil,
                     contentType: String = "application/json", accept: String = "application/json",
                     forceAuthRefresh: Bool = false) async throws -> HTTPClientRequest {
        var request = HTTPClientRequest(url: url(path: path, query: query))
        request.method = method.http
        request.headers.add(name: "Accept", value: accept)
        request.headers.add(name: "User-Agent", value: "Crowsnest/0.3")
        if let auth = try await authorization(forceRefresh: forceAuthRefresh) {
            request.headers.add(name: "Authorization", value: auth)
        }
        if let body {
            request.headers.add(name: "Content-Type", value: contentType)
            request.body = .bytes(ByteBuffer(data: body))
        }
        return request
    }

    /// Performs a request and returns the response body; non-2xx responses throw ``KubeError/api(status:reason:message:)``.
    public func send(_ method: Method, path: String, query: [String: String] = [:], body: Data? = nil,
                     contentType: String = "application/json", accept: String = "application/json",
                     timeout: TimeAmount = .seconds(30)) async throws -> Data {
        if let demo {
            return try await demo.handle(method, path: path, query: query, body: body, contentType: contentType)
        }
        var attempt = 0
        while true {
            let request = try await makeRequest(method, path: path, query: query, body: body, contentType: contentType,
                                                accept: accept, forceAuthRefresh: attempt > 0)
            let response: HTTPClientResponse
            do {
                response = try await http.execute(request, timeout: timeout)
            } catch {
                throw KubeError.transport(Self.describe(error))
            }
            let buffer = try await response.body.collect(upTo: 256 << 20)
            let data = Data(buffer: buffer)
            if (200..<300).contains(Int(response.status.code)) { return data }
            if response.status.code == 401, case .exec = config.auth, attempt == 0 {
                attempt += 1
                continue
            }
            throw Self.apiError(status: Int(response.status.code), body: data)
        }
    }

    static func apiError(status: Int, body: Data) -> KubeError {
        if let json = try? JSONValue(jsonData: body), json["kind"]?.string == "Status" {
            return .api(status: status, reason: json["reason"]?.string, message: json["message"]?.string ?? "Error")
        }
        let text = String(decoding: body.prefix(500), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return .api(status: status, reason: nil, message: text.isEmpty ? HTTPResponseStatus(statusCode: status).reasonPhrase : text)
    }

    static func describe(_ error: Error) -> String {
        let text = String(describing: error)
        if text.contains("Connection refused") { return "Server unreachable (connection refused)" }
        if let e = error as? HTTPClientError {
            if e == .connectTimeout || e == .deadlineExceeded { return "Timed out – server unreachable" }
            return String(describing: e)
        }
        if let e = error as? NIOSSLError { return "TLS: \(e)" }
        return String(describing: error)
    }

    public func json(_ method: Method = .get, path: String, query: [String: String] = [:], body: JSONValue? = nil,
                     contentType: String = "application/json") async throws -> JSONValue {
        let data = try await send(method, path: path, query: query, body: try body?.jsonData(), contentType: contentType)
        return data.isEmpty ? .null : try JSONValue(jsonData: data)
    }

    // MARK: - Resources

    /// Lists objects of a kind. `namespace == nil` lists across all namespaces.
    public func list(_ kind: ResourceKind, namespace: String? = nil, labelSelector: String? = nil,
                     fieldSelector: String? = nil) async throws -> [KubeObject] {
        var query: [String: String] = [:]
        if let labelSelector { query["labelSelector"] = labelSelector }
        if let fieldSelector { query["fieldSelector"] = fieldSelector }
        let list = try await json(path: kind.path(namespace: namespace), query: query)
        return (list["items"]?.array ?? []).map { item in
            var item = item
            // List items omit kind/apiVersion; add them so the object is self-describing.
            if item["kind"] == nil { item["kind"] = .string(kind.kind) }
            if item["apiVersion"] == nil { item["apiVersion"] = .string(kind.apiVersion) }
            return KubeObject(item)
        }
    }

    public func get(_ kind: ResourceKind, name: String, namespace: String?) async throws -> KubeObject {
        KubeObject(try await json(path: kind.path(namespace: namespace, name: name)))
    }

    public func delete(_ kind: ResourceKind, name: String, namespace: String?) async throws {
        _ = try await send(.delete, path: kind.path(namespace: namespace, name: name),
                           body: try JSONValue.object(["propagationPolicy": "Background"]).jsonData())
    }

    /// Replaces an object (`PUT`), e.g. after editing its YAML.
    @discardableResult
    public func replace(_ kind: ResourceKind, object: JSONValue) async throws -> KubeObject {
        guard let name = object.value(at: "metadata.name")?.string else {
            throw KubeError.invalidInput("metadata.name is missing")
        }
        let ns = object.value(at: "metadata.namespace")?.string
        return KubeObject(try await json(.put, path: kind.path(namespace: ns, name: name), body: object))
    }

    /// Creates an object (`POST`).
    @discardableResult
    public func create(_ kind: ResourceKind, object: JSONValue, namespace: String?) async throws -> KubeObject {
        KubeObject(try await json(.post, path: kind.path(namespace: namespace), body: object))
    }

    @discardableResult
    public func mergePatch(_ kind: ResourceKind, name: String, namespace: String?, patch: JSONValue) async throws -> KubeObject {
        KubeObject(try await json(.patch, path: kind.path(namespace: namespace, name: name), body: patch,
                                  contentType: "application/merge-patch+json"))
    }

    public func scale(_ kind: ResourceKind, name: String, namespace: String?, replicas: Int) async throws {
        try await mergePatch(kind, name: name, namespace: namespace, patch: ["spec": ["replicas": .int(Int64(replicas))]])
    }

    /// Equivalent of `kubectl rollout restart`.
    public func restart(_ kind: ResourceKind, name: String, namespace: String?) async throws {
        let now = Date.now.formatted(.iso8601)
        let patch: JSONValue = ["spec": ["template": ["metadata": ["annotations": [
            "kubectl.kubernetes.io/restartedAt": .string(now),
        ]]]]]
        try await mergePatch(kind, name: name, namespace: namespace, patch: patch)
    }

    /// Cordon / uncordon a node.
    public func setUnschedulable(node: String, _ unschedulable: Bool) async throws {
        try await mergePatch(.nodes, name: node, namespace: nil, patch: ["spec": ["unschedulable": .bool(unschedulable)]])
    }

    /// Manually triggers a CronJob, like `kubectl create job --from=cronjob/<name>`.
    @discardableResult
    public func trigger(cronJob: KubeObject) async throws -> KubeObject {
        guard let template = cronJob["spec.jobTemplate"] else { throw KubeError.invalidInput("CronJob has no jobTemplate") }
        let suffix = String(Int(Date.now.timeIntervalSince1970) % 1_000_000)
        let name = String(cronJob.name.prefix(52)) + "-manual-\(suffix)"
        var job: JSONValue = ["apiVersion": "batch/v1", "kind": "Job", "metadata": [
            "name": .string(name),
            "namespace": .string(cronJob.namespace ?? "default"),
            "annotations": ["cronjob.kubernetes.io/instantiate": "manual"],
            "ownerReferences": [[
                "apiVersion": "batch/v1", "kind": "CronJob", "name": .string(cronJob.name),
                "uid": .string(cronJob.uid ?? ""), "controller": false,
            ]],
        ]]
        job["spec"] = template["spec"]
        if let labels = template.value(at: "metadata.labels") { job.set(labels, at: ["metadata", "labels"]) }
        return try await create(.jobs, object: job, namespace: cronJob.namespace)
    }

    // MARK: - Pods

    public struct LogOptions: Sendable, Equatable {
        public var container: String?
        public var tailLines: Int?
        public var previous = false
        public var timestamps = false

        public init(container: String? = nil, tailLines: Int? = 500, previous: Bool = false, timestamps: Bool = false) {
            self.container = container
            self.tailLines = tailLines
            self.previous = previous
            self.timestamps = timestamps
        }

        func query(follow: Bool) -> [String: String] {
            var q: [String: String] = [:]
            if let container { q["container"] = container }
            if let tailLines { q["tailLines"] = String(tailLines) }
            if previous { q["previous"] = "true" }
            if timestamps { q["timestamps"] = "true" }
            if follow { q["follow"] = "true" }
            return q
        }
    }

    public func logs(pod: String, namespace: String, options: LogOptions) async throws -> String {
        let data = try await send(.get, path: ResourceKind.pods.path(namespace: namespace, name: pod, subresource: "log"),
                                  query: options.query(follow: false), accept: "*/*", timeout: .seconds(60))
        return String(decoding: data, as: UTF8.self)
    }

    /// Streams log lines (`follow=true`). Each element is a batch of complete lines.
    public nonisolated func followLogs(pod: String, namespace: String, options: LogOptions) -> AsyncThrowingStream<[String], Error> {
        if let demo { return Self.demoLogStream(demo, client: self, pod: pod, namespace: namespace, options: options) }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try await self.makeRequest(
                        .get, path: ResourceKind.pods.path(namespace: namespace, name: pod, subresource: "log"),
                        query: options.query(follow: true), accept: "*/*")
                    let response = try await self.http.execute(request, deadline: .now() + .hours(24))
                    guard response.status.code == 200 else {
                        let body = try await response.body.collect(upTo: 1 << 20)
                        throw Self.apiError(status: Int(response.status.code), body: Data(buffer: body))
                    }
                    var pending: [UInt8] = []
                    for try await chunk in response.body {
                        pending.append(contentsOf: chunk.readableBytesView)
                        guard let lastNewline = pending.lastIndex(of: 0x0A) else { continue }
                        let complete = pending[..<lastNewline]
                        let lines = complete.split(separator: 0x0A, omittingEmptySubsequences: false)
                            .map { String(decoding: $0, as: UTF8.self) }
                        pending.removeSubrange(...lastNewline)
                        continuation.yield(lines)
                    }
                    if !pending.isEmpty { continuation.yield([String(decoding: pending, as: UTF8.self)]) }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private nonisolated static func demoLogStream(_ demo: DemoCluster, client: KubeClient, pod: String, namespace: String,
                                                  options: LogOptions) -> AsyncThrowingStream<[String], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let initial = try await client.logs(pod: pod, namespace: namespace, options: options)
                    continuation.yield(initial.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init))
                    while !Task.isCancelled {
                        try await Task.sleep(for: .milliseconds(1500))
                        if let line = try await demo.liveLogLine(pod: pod, namespace: namespace, container: options.container) {
                            continuation.yield([line])
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Pods selected by a workload/service selector.
    public func pods(matching selector: String, namespace: String?) async throws -> [KubeObject] {
        try await list(.pods, namespace: namespace, labelSelector: selector)
    }

    /// Events whose `involvedObject` is the given object.
    public func events(for object: KubeObject) async throws -> [KubeObject] {
        var selector = "involvedObject.name=\(object.name),involvedObject.kind=\(object.kind)"
        if let uid = object.uid { selector = "involvedObject.uid=\(uid)" }
        let events = try await list(.events, namespace: object.namespace, fieldSelector: selector)
        return events.sorted { (EventInfo.lastSeen($0) ?? .distantPast) > (EventInfo.lastSeen($1) ?? .distantPast) }
    }

    // MARK: - Cluster

    public struct ServerVersion: Sendable, Equatable {
        public var gitVersion: String
        public var platform: String
    }

    public func serverVersion() async throws -> ServerVersion {
        let v = try await json(path: "/version")
        return ServerVersion(gitVersion: v["gitVersion"]?.string ?? "?", platform: v["platform"]?.string ?? "")
    }

    public func namespaceNames() async throws -> [String] {
        try await list(.namespaces).map(\.name).sorted()
    }

    /// Kinds for all installed CRDs.
    public func customResourceKinds() async throws -> [ResourceKind] {
        try await list(.customResourceDefinitions)
            .compactMap(ResourceKind.init(crd:))
            .sorted { ($0.group, $0.kind) < ($1.group, $1.kind) }
    }

    /// Usage from metrics-server (`metrics.k8s.io`), keyed by "namespace/name"; `nil` if not installed.
    public func podMetrics(namespace: String?) async throws -> [String: PodUsage]? {
        let kind = ResourceKind(kind: "PodMetrics", group: "metrics.k8s.io", version: "v1beta1", plural: "pods", category: .cluster)
        do {
            var result: [String: PodUsage] = [:]
            for item in try await list(kind, namespace: namespace) {
                var usage = PodUsage()
                for c in item["containers"]?.array ?? [] {
                    var container = ResourceUsage()
                    container.add(cpu: c.value(at: "usage.cpu")?.string, memory: c.value(at: "usage.memory")?.string)
                    usage.total.cpu += container.cpu
                    usage.total.memory += container.memory
                    if let name = c["name"]?.string { usage.containers[name] = container }
                }
                result["\(item.namespace ?? "")/\(item.name)"] = usage
            }
            return result
        } catch let e as KubeError where [404, 503].contains(e.httpStatus) {
            return nil
        }
    }

    public func nodeMetrics() async throws -> [String: ResourceUsage]? {
        let kind = ResourceKind(kind: "NodeMetrics", group: "metrics.k8s.io", version: "v1beta1", plural: "nodes",
                                namespaced: false, category: .cluster)
        do {
            var result: [String: ResourceUsage] = [:]
            for item in try await list(kind) {
                var usage = ResourceUsage()
                usage.add(cpu: item["usage.cpu"]?.string, memory: item["usage.memory"]?.string)
                result[item.name] = usage
            }
            return result
        } catch let e as KubeError where [404, 503].contains(e.httpStatus) {
            return nil
        }
    }
}

/// CPU in cores and memory in bytes.
public struct ResourceUsage: Sendable, Equatable {
    public var cpu: Double = 0
    public var memory: Double = 0

    public init(cpu: Double = 0, memory: Double = 0) {
        self.cpu = cpu
        self.memory = memory
    }

    mutating func add(cpu: String?, memory: String?) {
        self.cpu += cpu.flatMap(Quantity.parse) ?? 0
        self.memory += memory.flatMap(Quantity.parse) ?? 0
    }
}

/// Keeps one ``KubeClient`` per connection for the app's lifetime and
/// replaces it when the kubeconfig entry changes.
public actor KubeClientPool {
    public static let shared = KubeClientPool()
    private var clients: [String: KubeClient] = [:]

    public func client(for config: ConnectionConfig) async throws -> KubeClient {
        if let existing = clients[config.contextName] {
            if existing.config == config { return existing }
            await existing.shutdown()
        }
        let client = try KubeClient(config: config)
        clients[config.contextName] = client
        return client
    }
}

extension KubeClient {
    nonisolated func urlForTesting(path: String, query: [String: String]) -> String {
        Self.buildURL(server: config.server, path: path, query: query)
    }
}
