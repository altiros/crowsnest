import Foundation

/// An interactive process in a container (`kubectl exec -it`).
public final class ExecSession: Sendable {
    public enum Event: Sendable {
        case output([UInt8])
        /// The process ended. `exitCode` is `nil` if the server didn't report one.
        case exited(exitCode: Int?, message: String?)
    }

    /// Output and the final exit; throws on connection errors.
    public let events: AsyncThrowingStream<Event, Error>
    private let connection: ChannelConnection

    // Channel numbers of the exec protocol.
    static let stdin: UInt8 = 0, stdout: UInt8 = 1, stderr: UInt8 = 2, error: UInt8 = 3, resize: UInt8 = 4

    init(connection: ChannelConnection) {
        self.connection = connection
        events = AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var finished = false
                    for try await message in connection.messages {
                        switch message.channel {
                        case Self.stdout, Self.stderr:
                            if !message.data.isEmpty { continuation.yield(.output(message.data)) }
                        case Self.error:
                            let (code, text) = Self.parseStatus(message.data)
                            continuation.yield(.exited(exitCode: code, message: text))
                            finished = true
                        default:
                            continue
                        }
                    }
                    if !finished { continuation.yield(.exited(exitCode: nil, message: nil)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Sends keyboard input.
    public func write(_ bytes: some Sequence<UInt8>) {
        connection.send(channel: Self.stdin, bytes)
    }

    public func write(_ text: String) { write(Array(text.utf8)) }

    /// Tells the TTY its new size.
    public func resize(columns: Int, rows: Int) {
        let json = #"{"Width":\#(max(columns, 1)),"Height":\#(max(rows, 1))}"#
        connection.send(channel: Self.resize, Array(json.utf8))
    }

    public func close() { connection.close() }

    /// Parses the `metav1.Status` sent on the error channel when the process ends.
    static func parseStatus(_ data: [UInt8]) -> (Int?, String?) {
        guard let status = try? JSONValue(jsonData: Data(data)) else {
            let text = String(decoding: data, as: UTF8.self)
            return (nil, text.isEmpty ? nil : text)
        }
        if status["status"]?.string == "Success" { return (0, nil) }
        let causes = status.value(at: "details.causes")?.array ?? []
        let code = causes.first { $0["reason"]?.string == "ExitCode" }?["message"]?.string.flatMap { Int($0) }
        return (code, code == nil ? status["message"]?.string : nil)
    }
}

extension KubeClient {
    /// Shell command that prefers bash and falls back to sh, like Lens.
    public static let defaultShell = ["sh", "-c", "export TERM=xterm-256color; command -v bash >/dev/null 2>&1 && exec bash || exec sh"]

    /// Starts an interactive process with a TTY in a container.
    public func exec(pod: String, namespace: String, container: String?, command: [String] = KubeClient.defaultShell,
                     columns: Int = 80, rows: Int = 24) async throws -> ExecSession {
        var query: [(String, String)] = command.map { ("command", $0) }
        if let container { query.append(("container", container)) }
        query += [("stdin", "true"), ("stdout", "true"), ("stderr", "false"), ("tty", "true")]
        let connection = try await openChannel(
            path: ResourceKind.pods.path(namespace: namespace, name: pod, subresource: "exec"),
            query: query, protocols: ["v5.channel.k8s.io", "v4.channel.k8s.io"])
        let session = ExecSession(connection: connection)
        session.resize(columns: columns, rows: rows)
        return session
    }
}
