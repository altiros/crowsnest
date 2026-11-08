import CrowsnestKit
import Foundation

/// Kubeconfig files imported into the app container. iPadOS has no `~/.kube`,
/// so users import files (Files app, AirDrop, clipboard) instead.
public enum KubeconfigStore {
    public struct ImportResult: Sendable {
        public var contexts: [String]
        public var warnings: [String]
    }

    public static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "kubeconfigs", directoryHint: .isDirectory)
    }

    public static func files() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Validates and stores a kubeconfig.
    @discardableResult
    public static func importConfig(text: String, suggestedName: String) throws -> ImportResult {
        let config: KubeConfig
        do {
            config = try KubeConfig.parse(text)
        } catch {
            let looksLikeKubeconfig = text.contains("clusters:") && text.contains("contexts:")
            throw KubeError.invalidConfig(looksLikeKubeconfig
                ? "Could not read the kubeconfig (\(error.localizedDescription))."
                : "The text is not a kubeconfig (no \"clusters:\" and \"contexts:\"). It starts with: \"\(text.prefix(40))…\"")
        }
        guard !config.contexts.isEmpty else {
            throw KubeError.invalidConfig("The file contains no contexts")
        }
        let referencesFiles = config.clusters.contains { $0.cluster.certificateAuthority != nil }
            || config.users.contains { $0.user.clientCertificate != nil || $0.user.clientKey != nil || $0.user.tokenFile != nil }
        if referencesFiles {
            throw KubeError.invalidConfig(
                "The kubeconfig references certificate or key files that are not available here. "
                    + "Export it with \"kubectl config view --raw --flatten\" (data embedded).")
        }
        var warnings: [String] = []
        #if !os(macOS)
        let execUsers = config.users.filter { $0.user.exec != nil }.map(\.name)
        if !execUsers.isEmpty {
            warnings.append("exec plugins (\(execUsers.joined(separator: ", "))) are not supported on this device – these contexts cannot log in.")
        }
        #endif

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = uniqueURL(for: suggestedName)
        #if os(iOS)
        try Data(text.utf8).write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try Data(text.utf8).write(to: url, options: [.atomic])
        #endif
        return ImportResult(contexts: config.contextNames, warnings: warnings)
    }

    /// Imports a file picked via `fileImporter` (security-scoped URL).
    @discardableResult
    public static func importConfig(from url: URL) throws -> ImportResult {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let text = try String(contentsOf: url, encoding: .utf8)
        return try importConfig(text: text, suggestedName: url.lastPathComponent)
    }

    public static func remove(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    private static func uniqueURL(for name: String) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        var base = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        if base.isEmpty || base == "config" { base = "kubeconfig" }
        var url = directory.appending(path: base)
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appending(path: "\(base)-\(counter)")
            counter += 1
        }
        return url
    }
}
