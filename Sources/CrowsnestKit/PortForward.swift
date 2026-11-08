import Foundation
import NIOCore
import NIOPosix
import Synchronization

/// A local TCP listener that tunnels every connection to a pod port (`kubectl port-forward`).
public final class PortForwarder: Sendable, Identifiable {
    public struct Status: Sendable, Equatable {
        public var activeConnections = 0
        public var totalConnections = 0
        public var lastError: String?
    }

    public let id = UUID()
    public let pod: String
    public let namespace: String
    public let remotePort: Int
    public let localPort: Int
    public let address: String

    private let state = Mutex(Status())
    private let serverChannel: any Channel
    private let task = Mutex<Task<Void, Never>?>(nil)
    private let connections = Mutex<[ObjectIdentifier: any Channel]>([:])
    private let stopped = Mutex(false)

    public var status: Status { state.withLock { $0 } }
    public var url: URL? { URL(string: "http://\(address == "0.0.0.0" ? "localhost" : address):\(localPort)") }

    init(pod: String, namespace: String, remotePort: Int, localPort: Int, address: String, serverChannel: any Channel) {
        self.pod = pod
        self.namespace = namespace
        self.remotePort = remotePort
        self.localPort = localPort
        self.address = address
        self.serverChannel = serverChannel
    }

    /// Stops listening and closes all tunnelled connections.
    public func stop() {
        stopped.withLock { $0 = true }
        task.withLock { $0?.cancel() }
        serverChannel.close(promise: nil)
        for channel in connections.withLock({ Array($0.values) }) { channel.close(promise: nil) }
    }

    public var isStopped: Bool { stopped.withLock { $0 } }

    fileprivate func start(_ work: Task<Void, Never>) { task.withLock { $0 = work } }

    fileprivate func update(_ change: (inout Status) -> Void) { state.withLock { change(&$0) } }

    /// Tunnels one accepted connection.
    fileprivate func tunnel(_ connection: NIOAsyncChannel<ByteBuffer, ByteBuffer>, client: KubeClient) async {
        let key = ObjectIdentifier(connection.channel)
        connections.withLock { $0[key] = connection.channel }
        update { $0.activeConnections += 1; $0.totalConnections += 1 }
        defer {
            connections.withLock { $0[key] = nil }
            update { $0.activeConnections -= 1 }
        }
        if isStopped { connection.channel.close(promise: nil); return }
        do {
            let ws = try await client.openChannel(
                path: ResourceKind.pods.path(namespace: namespace, name: pod, subresource: "portforward"),
                query: [("ports", String(remotePort))], protocols: ["v4.channel.k8s.io"])
            defer { ws.close() }
            try await connection.executeThenClose { inbound, outbound in
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for try await buffer in inbound {
                            ws.send(channel: 0, buffer.readableBytesView)
                        }
                    }
                    group.addTask {
                        // Kubelets may first send the port number (2 bytes, little endian) as a separate
                        // message on each channel; newer API servers don't. Drop it only in that exact form.
                        let portPrefix = [UInt8(self.remotePort & 0xFF), UInt8((self.remotePort >> 8) & 0xFF)]
                        var seenChannels: Set<UInt8> = []
                        var errorText: [UInt8] = []
                        for try await message in ws.messages {
                            let isFirst = seenChannels.insert(message.channel).inserted
                            if isFirst && message.data == portPrefix { continue }
                            let data = message.data
                            guard !data.isEmpty else { continue }
                            if message.channel == 0 {
                                try await outbound.write(ByteBuffer(bytes: data))
                            } else if message.channel == 1 {
                                errorText.append(contentsOf: data)
                                throw KubeError.transport(String(decoding: errorText, as: UTF8.self))
                            }
                        }
                    }
                    try await group.next()
                    group.cancelAll()
                }
            }
        } catch is CancellationError {
        } catch {
            update { $0.lastError = error.localizedDescription }
        }
    }
}

extension KubeClient {
    /// Listens on `address:localPort` (0 = any free port) and forwards connections to `remotePort` of a pod.
    public func forward(pod: String, namespace: String, remotePort: Int, localPort: Int = 0,
                        address: String = "127.0.0.1") async throws -> PortForwarder {
        let server: NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never>
        do {
            server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .bind(host: address, port: localPort) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
                    }
                }
        } catch {
            throw KubeError.transport("Local port \(localPort) is not available (\(Self.describe(error)))")
        }
        let forwarder = PortForwarder(pod: pod, namespace: namespace, remotePort: remotePort,
                                      localPort: server.channel.localAddress?.port ?? localPort,
                                      address: address, serverChannel: server.channel)
        let work = Task<Void, Never> {
            try? await server.executeThenClose { inbound in
                try await withThrowingDiscardingTaskGroup { group in
                    for try await connection in inbound {
                        group.addTask { await forwarder.tunnel(connection, client: self) }
                    }
                }
            }
        }
        forwarder.start(work)
        return forwarder
    }

    /// Resolves a service port to a running pod and its container port, like `kubectl port-forward svc/…`.
    public func forwardTarget(service: KubeObject, port: Int) async throws -> (pod: String, port: Int) {
        let ports = service["spec.ports"]?.array ?? []
        guard let entry = ports.first(where: { $0["port"]?.int == port }) else {
            throw KubeError.invalidInput("Service \(service.name) has no port \(port)")
        }
        guard let selector = service["spec.selector"]?.stringMap, !selector.isEmpty else {
            throw KubeError.invalidInput("Service \(service.name) has no selector – no pods to forward to")
        }
        let labelSelector = selector.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        let pods = try await list(.pods, namespace: service.namespace, labelSelector: labelSelector)
            .filter { $0["status.phase"]?.string == "Running" }
        let ready = pods.first { pod in
            (pod["status.conditions"]?.array ?? []).contains { $0["type"]?.string == "Ready" && $0["status"]?.string == "True" }
        }
        guard let pod = ready ?? pods.first else {
            throw KubeError.invalidInput("No running pod for service \(service.name)")
        }
        return (pod.name, Self.containerPort(for: entry["targetPort"], servicePort: port, in: pod))
    }

    /// Maps a service `targetPort` (number or port name) to a container port of a pod.
    static func containerPort(for targetPort: JSONValue?, servicePort: Int, in pod: KubeObject) -> Int {
        if let number = targetPort?.int { return number }
        if let name = targetPort?.string {
            if let number = Int(name) { return number }
            for container in pod["spec.containers"]?.array ?? [] {
                for p in container["ports"]?.array ?? [] where p["name"]?.string == name {
                    if let number = p["containerPort"]?.int { return number }
                }
            }
        }
        return servicePort
    }
}
