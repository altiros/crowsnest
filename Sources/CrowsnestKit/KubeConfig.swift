import Foundation
import Yams

/// Model of a kubeconfig file (`~/.kube/config`), including merging of
/// multiple files as with `KUBECONFIG=a:b`.
public struct KubeConfig: Sendable, Codable, Equatable {
    public var clusters: [NamedCluster]
    public var users: [NamedUser]
    public var contexts: [NamedContext]
    public var currentContext: String?

    public init(clusters: [NamedCluster] = [], users: [NamedUser] = [], contexts: [NamedContext] = [], currentContext: String? = nil) {
        self.clusters = clusters
        self.users = users
        self.contexts = contexts
        self.currentContext = currentContext
    }

    enum CodingKeys: String, CodingKey {
        case clusters, users, contexts
        case currentContext = "current-context"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clusters = try c.decodeIfPresent([NamedCluster].self, forKey: .clusters) ?? []
        users = try c.decodeIfPresent([NamedUser].self, forKey: .users) ?? []
        contexts = try c.decodeIfPresent([NamedContext].self, forKey: .contexts) ?? []
        currentContext = try c.decodeIfPresent(String.self, forKey: .currentContext).flatMap { $0.isEmpty ? nil : $0 }
    }

    public struct NamedCluster: Sendable, Codable, Equatable {
        public var name: String
        public var cluster: Cluster
    }

    public struct NamedUser: Sendable, Codable, Equatable {
        public var name: String
        public var user: User
    }

    public struct NamedContext: Sendable, Codable, Equatable {
        public var name: String
        public var context: Context
    }

    public struct Cluster: Sendable, Codable, Equatable {
        public var server: String
        public var certificateAuthority: String?
        public var certificateAuthorityData: String?
        public var insecureSkipTLSVerify: Bool?
        public var tlsServerName: String?
        public var proxyURL: String?

        enum CodingKeys: String, CodingKey {
            case server
            case certificateAuthority = "certificate-authority"
            case certificateAuthorityData = "certificate-authority-data"
            case insecureSkipTLSVerify = "insecure-skip-tls-verify"
            case tlsServerName = "tls-server-name"
            case proxyURL = "proxy-url"
        }
    }

    public struct User: Sendable, Codable, Equatable {
        public var clientCertificate: String?
        public var clientCertificateData: String?
        public var clientKey: String?
        public var clientKeyData: String?
        public var token: String?
        public var tokenFile: String?
        public var username: String?
        public var password: String?
        public var exec: ExecConfig?
        public var authProvider: AuthProvider?

        public init() {}

        enum CodingKeys: String, CodingKey {
            case clientCertificate = "client-certificate"
            case clientCertificateData = "client-certificate-data"
            case clientKey = "client-key"
            case clientKeyData = "client-key-data"
            case token, tokenFile, username, password, exec
            case authProvider = "auth-provider"
        }
    }

    public struct AuthProvider: Sendable, Codable, Equatable {
        public var name: String
    }

    public struct ExecConfig: Sendable, Codable, Equatable {
        public var command: String
        public var args: [String]?
        public var env: [EnvVar]?
        public var apiVersion: String?
        public var installHint: String?
        public var provideClusterInfo: Bool?

        public struct EnvVar: Sendable, Codable, Equatable {
            public var name: String
            public var value: String
        }
    }

    public struct Context: Sendable, Codable, Equatable {
        public var cluster: String
        public var user: String?
        public var namespace: String?
    }
}

// MARK: - Loading

extension KubeConfig {
    /// Files referenced by `KUBECONFIG`, or `~/.kube/config`.
    public static func defaultFileURLs(environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        if let value = environment["KUBECONFIG"], !value.isEmpty {
            return value.split(separator: ":").map { URL(fileURLWithPath: expandTilde(String($0))) }
        }
        return [URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".kube/config")]
    }

    /// Loads and merges kubeconfig files. The first definition of a name wins,
    /// like kubectl. Missing files are skipped unless none can be read.
    public static func load(from urls: [URL]) throws -> KubeConfig {
        var merged = KubeConfig()
        var loadedAny = false
        var firstError: Error?
        for url in urls {
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                let config = try parse(text, baseDirectory: url.deletingLastPathComponent())
                merged.merge(config)
                loadedAny = true
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if !loadedAny {
            if let firstError { throw firstError }
            throw KubeError.invalidConfig("No kubeconfig found")
        }
        return merged
    }

    public static func parse(_ yaml: String, baseDirectory: URL? = nil) throws -> KubeConfig {
        var config: KubeConfig
        do {
            config = try YAMLDecoder().decode(KubeConfig.self, from: yaml)
        } catch {
            throw KubeError.invalidConfig(String(describing: error))
        }
        if let baseDirectory { config.resolvePaths(relativeTo: baseDirectory) }
        return config
    }

    mutating func merge(_ other: KubeConfig) {
        for c in other.clusters where !clusters.contains(where: { $0.name == c.name }) { clusters.append(c) }
        for u in other.users where !users.contains(where: { $0.name == u.name }) { users.append(u) }
        for c in other.contexts where !contexts.contains(where: { $0.name == c.name }) { contexts.append(c) }
        if currentContext == nil { currentContext = other.currentContext }
    }

    mutating func resolvePaths(relativeTo dir: URL) {
        func resolve(_ path: String?) -> String? {
            guard let path, !path.isEmpty else { return path }
            let expanded = KubeConfig.expandTilde(path)
            if expanded.hasPrefix("/") { return expanded }
            return dir.appending(path: expanded).standardizedFileURL.path
        }
        for i in clusters.indices {
            clusters[i].cluster.certificateAuthority = resolve(clusters[i].cluster.certificateAuthority)
        }
        for i in users.indices {
            users[i].user.clientCertificate = resolve(users[i].user.clientCertificate)
            users[i].user.clientKey = resolve(users[i].user.clientKey)
            users[i].user.tokenFile = resolve(users[i].user.tokenFile)
            // kubectl resolves exec commands relative to the file only if they contain a path separator.
            if let cmd = users[i].user.exec?.command, cmd.contains("/") {
                users[i].user.exec?.command = resolve(cmd) ?? cmd
            }
        }
    }

    static func expandTilde(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        return NSHomeDirectory() + path.dropFirst()
    }

    public var contextNames: [String] { contexts.map(\.name) }
}

// MARK: - Resolving a context into a connection

/// Everything needed to talk to one cluster as one user.
public struct ConnectionConfig: Sendable, Equatable {
    public enum Auth: Sendable, Equatable {
        case none
        case bearer(String)
        case tokenFile(String)
        case basic(username: String, password: String)
        case exec(KubeConfig.ExecConfig)
    }

    public var contextName: String
    public var clusterName: String
    public var userName: String?
    public var server: URL
    public var defaultNamespace: String?
    public var caPEM: Data?
    public var insecureSkipTLSVerify: Bool
    public var tlsServerName: String?
    public var clientCertificatePEM: Data?
    public var clientKeyPEM: Data?
    public var auth: Auth

    public init(contextName: String, clusterName: String, userName: String? = nil, server: URL, defaultNamespace: String? = nil,
                caPEM: Data? = nil, insecureSkipTLSVerify: Bool = false, tlsServerName: String? = nil,
                clientCertificatePEM: Data? = nil, clientKeyPEM: Data? = nil, auth: Auth = .none) {
        self.contextName = contextName
        self.clusterName = clusterName
        self.userName = userName
        self.server = server
        self.defaultNamespace = defaultNamespace
        self.caPEM = caPEM
        self.insecureSkipTLSVerify = insecureSkipTLSVerify
        self.tlsServerName = tlsServerName
        self.clientCertificatePEM = clientCertificatePEM
        self.clientKeyPEM = clientKeyPEM
        self.auth = auth
    }
}

extension KubeConfig {
    public func connection(forContext name: String) throws -> ConnectionConfig {
        guard let ctx = contexts.first(where: { $0.name == name })?.context else {
            throw KubeError.invalidConfig("Context '\(name)' not found")
        }
        guard let cluster = clusters.first(where: { $0.name == ctx.cluster })?.cluster else {
            throw KubeError.invalidConfig("Cluster '\(ctx.cluster)' not found")
        }
        guard let server = URL(string: cluster.server), server.scheme != nil else {
            throw KubeError.invalidConfig("Invalid server URL '\(cluster.server)'")
        }
        let user = ctx.user.flatMap { u in users.first(where: { $0.name == u })?.user } ?? User()

        func data(inline: String?, file: String?, what: String) throws -> Data? {
            if let inline, !inline.isEmpty {
                guard let d = Data(base64Encoded: inline, options: .ignoreUnknownCharacters) else {
                    throw KubeError.invalidConfig("\(what) is not valid base64")
                }
                return d
            }
            if let file, !file.isEmpty {
                do { return try Data(contentsOf: URL(fileURLWithPath: file)) } catch {
                    throw KubeError.invalidConfig("Could not read \(what): \(file)")
                }
            }
            return nil
        }

        let auth: ConnectionConfig.Auth
        if let exec = user.exec {
            auth = .exec(exec)
        } else if let token = user.token, !token.isEmpty {
            auth = .bearer(token)
        } else if let file = user.tokenFile, !file.isEmpty {
            auth = .tokenFile(file)
        } else if let u = user.username, let p = user.password {
            auth = .basic(username: u, password: p)
        } else if let provider = user.authProvider {
            throw KubeError.unsupported("auth-provider '\(provider.name)' is deprecated – switch to an exec plugin")
        } else {
            auth = .none
        }

        return ConnectionConfig(
            contextName: name,
            clusterName: ctx.cluster,
            userName: ctx.user,
            server: server,
            defaultNamespace: ctx.namespace,
            caPEM: try data(inline: cluster.certificateAuthorityData, file: cluster.certificateAuthority, what: "certificate-authority"),
            insecureSkipTLSVerify: cluster.insecureSkipTLSVerify ?? false,
            tlsServerName: cluster.tlsServerName,
            clientCertificatePEM: try data(inline: user.clientCertificateData, file: user.clientCertificate, what: "client-certificate"),
            clientKeyPEM: try data(inline: user.clientKeyData, file: user.clientKey, what: "client-key"),
            auth: auth
        )
    }
}
