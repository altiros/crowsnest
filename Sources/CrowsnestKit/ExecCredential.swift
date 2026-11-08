import Foundation

/// Result of a client-go credential plugin (`users[].user.exec`),
/// e.g. `aws eks get-token`, `gke-gcloud-auth-plugin`, `kubelogin`.
public struct ExecCredential: Sendable, Equatable {
    public var token: String?
    public var clientCertificatePEM: Data?
    public var clientKeyPEM: Data?
    public var expiration: Date?

    public func isValid(at date: Date = .now) -> Bool {
        guard let expiration else { return true }
        return expiration.addingTimeInterval(-30) > date
    }

    init(json: JSONValue) throws {
        guard let status = json["status"] else {
            throw KubeError.execPlugin("Response has no 'status' field")
        }
        token = status["token"]?.string
        clientCertificatePEM = status["clientCertificateData"]?.string.map { Data($0.utf8) }
        clientKeyPEM = status["clientKeyData"]?.string.map { Data($0.utf8) }
        expiration = status["expirationTimestamp"]?.string.flatMap(KubeDate.parse)
        if token == nil && clientCertificatePEM == nil {
            throw KubeError.execPlugin("Response contains neither a token nor a certificate")
        }
    }
}

#if os(macOS)
enum ExecCredentialRunner {
    /// GUI apps don't inherit the login shell's PATH, so add common tool locations.
    static let extraPathEntries: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
            "\(home)/.local/bin", "\(home)/bin", "\(home)/go/bin", "\(home)/.krew/bin",
            "\(home)/google-cloud-sdk/bin", "/opt/homebrew/share/google-cloud-sdk/bin",
            "/usr/local/share/google-cloud-sdk/bin",
        ]
    }()

    static func run(_ exec: KubeConfig.ExecConfig, server: URL) async throws -> ExecCredential {
        var env = ProcessInfo.processInfo.environment
        let path = (env["PATH"].map { $0.split(separator: ":").map(String.init) } ?? []) + extraPathEntries
        var seen = Set<String>()
        env["PATH"] = path.filter { seen.insert($0).inserted }.joined(separator: ":")
        for e in exec.env ?? [] { env[e.name] = e.value }

        let apiVersion = exec.apiVersion ?? "client.authentication.k8s.io/v1"
        var spec: JSONValue = ["interactive": false]
        if exec.provideClusterInfo == true {
            spec["cluster"] = ["server": .string(server.absoluteString)]
        }
        let info: JSONValue = ["apiVersion": .string(apiVersion), "kind": "ExecCredential", "spec": spec]
        env["KUBERNETES_EXEC_INFO"] = String(decoding: try info.jsonData(), as: UTF8.self)

        guard let executable = resolve(command: exec.command, path: env["PATH"] ?? "") else {
            var msg = "Command '\(exec.command)' not found"
            if let hint = exec.installHint { msg += "\n\(hint)" }
            throw KubeError.execPlugin(msg)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = exec.args ?? []
        process.environment = env
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        let (status, out, err): (Int32, Data, Data) = try await withCheckedThrowingContinuation { cont in
            let collector = OutputCollector()
            let group = DispatchGroup()
            group.enter()
            group.enter()
            group.enter()
            DispatchQueue.global().async {
                collector.out = stdout.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            DispatchQueue.global().async {
                collector.err = stderr.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            process.terminationHandler = { _ in group.leave() }
            do {
                try process.run()
            } catch {
                cont.resume(throwing: KubeError.execPlugin(error.localizedDescription))
                return
            }
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: timeout)
            group.notify(queue: .global()) {
                timeout.cancel()
                cont.resume(returning: (process.terminationStatus, collector.out, collector.err))
            }
        }

        guard status == 0 else {
            let message = String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw KubeError.execPlugin(message.isEmpty ? "exit code \(status)" : message)
        }
        do {
            return try ExecCredential(json: try JSONValue(jsonData: out))
        } catch let e as KubeError {
            throw e
        } catch {
            throw KubeError.execPlugin("Invalid JSON response")
        }
    }

    static func resolve(command: String, path: String) -> String? {
        if command.contains("/") {
            return FileManager.default.isExecutableFile(atPath: command) ? command : nil
        }
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(command)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private final class OutputCollector: @unchecked Sendable {
        var out = Data()
        var err = Data()
    }
}
#endif
