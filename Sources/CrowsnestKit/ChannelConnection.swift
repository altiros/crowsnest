import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOWebSocket

/// One message of Kubernetes' WebSocket channel protocol (`v4/v5.channel.k8s.io`):
/// every binary message starts with a byte naming the stream it belongs to.
public struct ChannelMessage: Sendable {
    public var channel: UInt8
    public var data: [UInt8]
}

/// WebSocket connection to a streaming endpoint of the API server (exec, attach, port-forward).
public final class ChannelConnection: Sendable {
    /// Subprotocol chosen by the server (e.g. `v5.channel.k8s.io`).
    public let negotiatedProtocol: String?
    /// Incoming messages; finishes when the server closes the connection.
    public let messages: AsyncThrowingStream<ChannelMessage, Error>
    private let outbound: AsyncStream<WebSocketFrame>.Continuation

    init(channel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>, negotiatedProtocol: String?) {
        self.negotiatedProtocol = negotiatedProtocol
        let (messages, messageSink) = AsyncThrowingStream.makeStream(of: ChannelMessage.self)
        let (outgoing, outbound) = AsyncStream.makeStream(of: WebSocketFrame.self)
        self.messages = messages
        self.outbound = outbound

        Task {
            do {
                try await channel.executeThenClose { inbound, writer in
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            for await frame in outgoing {
                                try await writer.write(frame)
                                if frame.opcode == .connectionClose { return }
                            }
                        }
                        group.addTask {
                            for try await frame in inbound {
                                switch frame.opcode {
                                case .binary, .text:
                                    var data = frame.unmaskedData
                                    guard let channel: UInt8 = data.readInteger() else { continue }
                                    messageSink.yield(ChannelMessage(channel: channel, data: Array(data.readableBytesView)))
                                case .ping:
                                    outbound.yield(WebSocketFrame(fin: true, opcode: .pong, maskKey: .random(), data: frame.unmaskedData))
                                case .connectionClose:
                                    return
                                default:
                                    continue
                                }
                            }
                        }
                        // Either side ending (server closed, or we closed) ends the connection.
                        try await group.next()
                        group.cancelAll()
                    }
                }
                messageSink.finish()
            } catch is CancellationError {
                messageSink.finish()
            } catch {
                messageSink.finish(throwing: KubeError.transport(KubeClient.describe(error)))
            }
            outbound.finish()
        }
    }

    /// Sends bytes on a channel (client frames must be masked).
    public func send(channel: UInt8, _ bytes: some Sequence<UInt8>) {
        var payload: [UInt8] = [channel]
        payload.append(contentsOf: bytes)
        outbound.yield(WebSocketFrame(fin: true, opcode: .binary, maskKey: .random(), data: ByteBuffer(bytes: payload)))
    }

    /// Closes the connection.
    public func close() {
        var data = ByteBuffer()
        data.write(webSocketErrorCode: .normalClosure)
        outbound.yield(WebSocketFrame(fin: true, opcode: .connectionClose, maskKey: .random(), data: data))
        outbound.finish()
    }

    deinit { outbound.finish() }
}

extension KubeClient {
    private enum UpgradeResult: Sendable {
        case websocket(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>, String?)
        case notUpgraded(NIOAsyncChannel<HTTPClientResponsePart, HTTPClientRequestPart>)
    }

    /// Opens a WebSocket to `path` (e.g. `…/pods/x/exec`). Query items may repeat (`command=…`).
    public func openChannel(path: String, query: [(String, String)], protocols: [String]) async throws -> ChannelConnection {
        do {
            return try await connectChannel(path: path, query: query, protocols: protocols, forceAuthRefresh: false)
        } catch let error as KubeError where error.httpStatus == 401 {
            guard case .exec = config.auth else { throw error }
            return try await connectChannel(path: path, query: query, protocols: protocols, forceAuthRefresh: true)
        }
    }

    private func connectChannel(path: String, query: [(String, String)], protocols: [String],
                                forceAuthRefresh: Bool) async throws -> ChannelConnection {
        let server = config.server
        guard let host = server.host else { throw KubeError.invalidConfig("Server-URL ohne Host") }
        let useTLS = server.scheme?.lowercased() != "http"
        let port = server.port ?? (useTLS ? 443 : 80)

        var prefix = server.path
        while prefix.hasSuffix("/") { prefix.removeLast() }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let queryString = query.map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: allowed) ?? $1)" }
            .joined(separator: "&")
        let uri = prefix + path + (queryString.isEmpty ? "" : "?" + queryString)

        var headers = HTTPHeaders()
        let defaultPort = useTLS ? 443 : 80
        headers.add(name: "Host", value: port == defaultPort ? host : "\(host):\(port)")
        headers.add(name: "User-Agent", value: "Crowsnest/0.4")
        headers.add(name: "Sec-WebSocket-Protocol", value: protocols.joined(separator: ", "))
        if let auth = try await authorization(forceRefresh: forceAuthRefresh) {
            headers.add(name: "Authorization", value: auth)
        }
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: uri, headers: headers)

        let isIPAddress = (try? SocketAddress(ipAddress: host, port: 0)) != nil
        let sni = config.tlsServerName ?? (isIPAddress ? nil : host)
        let sslContext = self.sslContext

        let result: UpgradeResult
        do {
            let future: EventLoopFuture<UpgradeResult> = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .connectTimeout(.seconds(10))
                .connect(host: host, port: port) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        if useTLS {
                            try channel.pipeline.syncOperations.addHandler(
                                NIOSSLClientHandler(context: sslContext, serverHostname: sni))
                        }
                        let upgrader = NIOTypedWebSocketClientUpgrader<UpgradeResult>(
                            maxFrameSize: 1 << 24,
                            upgradePipelineHandler: { channel, response in
                                channel.eventLoop.makeCompletedFuture {
                                    try channel.pipeline.syncOperations.addHandler(NIOWebSocketFrameAggregator(
                                        minNonFinalFragmentSize: 0, maxAccumulatedFrameCount: 1024,
                                        maxAccumulatedFrameSize: 1 << 24))
                                    let ws = try NIOAsyncChannel<WebSocketFrame, WebSocketFrame>(wrappingChannelSynchronously: channel)
                                    return .websocket(ws, response.headers.first(name: "Sec-WebSocket-Protocol"))
                                }
                            })
                        let configuration = NIOTypedHTTPClientUpgradeConfiguration(
                            upgradeRequestHead: requestHead,
                            upgraders: [upgrader],
                            notUpgradingCompletionHandler: { channel in
                                channel.eventLoop.makeCompletedFuture {
                                    .notUpgraded(try NIOAsyncChannel(wrappingChannelSynchronously: channel))
                                }
                            })
                        return try channel.pipeline.syncOperations.configureUpgradableHTTPClientPipeline(
                            configuration: .init(upgradeConfiguration: configuration))
                    }
                }
            result = try await future.get()
        } catch {
            throw KubeError.transport(Self.describe(error))
        }

        switch result {
        case .websocket(let channel, let negotiated):
            return ChannelConnection(channel: channel, negotiatedProtocol: negotiated)
        case .notUpgraded(let channel):
            throw await Self.readRejection(channel)
        }
    }

    /// Reads the HTTP response the server sent instead of switching protocols.
    private static func readRejection(_ channel: NIOAsyncChannel<HTTPClientResponsePart, HTTPClientRequestPart>) async -> KubeError {
        var status = 0
        var body = Data()
        do {
            try await channel.executeThenClose { inbound, _ in
                for try await part in inbound {
                    switch part {
                    case .head(let head): status = Int(head.status.code)
                    case .body(let buffer): if body.count < 1 << 20 { body.append(contentsOf: buffer.readableBytesView) }
                    case .end: return
                    }
                }
            }
        } catch {}
        guard status != 0 else { return .transport("The server rejected the WebSocket connection") }
        return apiError(status: status, body: body)
    }
}
