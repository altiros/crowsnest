import CrowsnestKit
import Foundation
import Observation

/// Helm chart repositories and their charts, shared by all windows (not tied to a cluster).
///
/// Repositories come from two places: the ones added in Crowsnest (stored in the app's settings) and, on the Mac,
/// the ones configured for the `helm` CLI (read-only – Crowsnest never changes Helm's own configuration).
@MainActor @Observable
public final class HelmCatalog {
    public static let shared = HelmCatalog()

    public private(set) var userRepositories: [HelmRepository]
    public private(set) var cliRepositories: [HelmRepository] = []
    public private(set) var charts: [HelmChart] = []
    /// Index errors by repository name.
    public private(set) var errors: [String: String] = [:]
    public private(set) var isLoading = false
    public private(set) var lastUpdate: Date?

    private var filesCache: [String: HelmChartFiles] = [:]
    private let defaults: UserDefaults

    /// Well-known repositories offered when adding one.
    public static let suggestions: [HelmRepository] = [
        HelmRepository(name: "bitnami", url: "https://charts.bitnami.com/bitnami"),
        HelmRepository(name: "prometheus-community", url: "https://prometheus-community.github.io/helm-charts"),
        HelmRepository(name: "grafana", url: "https://grafana.github.io/helm-charts"),
        HelmRepository(name: "ingress-nginx", url: "https://kubernetes.github.io/ingress-nginx"),
        HelmRepository(name: "jetstack", url: "https://charts.jetstack.io"),
        HelmRepository(name: "argo", url: "https://argoproj.github.io/argo-helm"),
        HelmRepository(name: "metrics-server", url: "https://kubernetes-sigs.github.io/metrics-server/"),
    ]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: SettingsKey.helmRepositories),
           let stored = try? JSONDecoder().decode([HelmRepository].self, from: data) {
            userRepositories = stored
        } else {
            userRepositories = []
        }
        #if os(macOS)
        cliRepositories = HelmRepositories.helmCLIRepositories()
        #endif
    }

    /// All repositories; one added in Crowsnest wins over a `helm` CLI repository of the same name.
    public var repositories: [HelmRepository] {
        let names = Set(userRepositories.map(\.name))
        return (userRepositories + cliRepositories.filter { !names.contains($0.name) })
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func isFromHelmCLI(_ repository: HelmRepository) -> Bool {
        !userRepositories.contains { $0.name == repository.name } && cliRepositories.contains(repository)
    }

    /// Adds a repository and loads its index. Returns an error message if the input is invalid.
    @discardableResult
    public func add(name: String, url: String) -> String? {
        if let problem = HelmRepository.validate(name: name, url: url, existing: repositories) { return problem }
        let repository = HelmRepository(name: name.trimmingCharacters(in: .whitespaces), url: url.trimmingCharacters(in: .whitespaces))
        userRepositories.append(repository)
        save()
        Task { await load([repository]) }
        return nil
    }

    public func remove(_ repository: HelmRepository) {
        userRepositories.removeAll { $0.name == repository.name }
        charts.removeAll { $0.repository.name == repository.name }
        errors[repository.name] = nil
        save()
    }

    public func loadIfNeeded() async {
        guard lastUpdate == nil, !isLoading else { return }
        await refresh()
    }

    /// Re-reads the `helm` CLI configuration and downloads all indexes.
    public func refresh() async {
        #if os(macOS)
        cliRepositories = HelmRepositories.helmCLIRepositories()
        #endif
        charts.removeAll { chart in !repositories.contains { $0.name == chart.repository.name } }
        await load(repositories)
    }

    private func load(_ repos: [HelmRepository]) async {
        isLoading = true
        defer { isLoading = false }
        await withTaskGroup(of: (HelmRepository, Result<[HelmChart], Error>).self) { group in
            for repo in repos {
                group.addTask { (repo, await Result { try await HelmRepositories.fetchIndex(repo) }) }
            }
            for await (repo, result) in group {
                charts.removeAll { $0.repository.name == repo.name }
                switch result {
                case .success(let loaded):
                    charts += loaded
                    errors[repo.name] = nil
                case .failure(let error):
                    errors[repo.name] = error.localizedDescription
                }
            }
        }
        charts.sort { ($0.name, $0.repository.name) < ($1.name, $1.repository.name) }
        lastUpdate = .now
    }

    /// Charts matching a search (name, description, keywords, repository).
    public func charts(matching query: String) -> [HelmChart] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return charts }
        return charts.filter { chart in
            chart.name.lowercased().contains(q) || chart.repository.name.lowercased().contains(q)
                || chart.latest.description.lowercased().contains(q)
                || chart.latest.keywords.contains { $0.lowercased().contains(q) }
        }
    }

    /// README, default values and Chart.yaml of a chart version (cached).
    public func files(for version: HelmChartVersion, in repository: HelmRepository) async throws -> HelmChartFiles {
        let key = "\(repository.name)/\(version.id)"
        if let cached = filesCache[key] { return cached }
        let files = try await HelmRepositories.fetchChartFiles(version, in: repository)
        filesCache[key] = files
        return files
    }

    /// A `helm install` command for the chart (adds the repository first if the `helm` CLI doesn't know it).
    public func installCommand(for version: HelmChartVersion, in repository: HelmRepository, namespace: String?) -> String {
        let ns = namespace.map { " --namespace \($0) --create-namespace" } ?? ""
        if let url = version.urls.first, url.hasPrefix("oci://") {
            let ref = url.split(separator: ":").dropLast().joined(separator: ":")  // without the tag
            return "helm install \(version.name) \(ref) --version \(version.version)\(ns)"
        }
        let install = "helm install \(version.name) \(repository.name)/\(version.name) --version \(version.version)\(ns)"
        return cliRepositories.contains(repository) ? install : "helm repo add \(repository.name) \(repository.url) && \(install)"
    }

    private func save() {
        if let data = try? JSONEncoder().encode(userRepositories) { defaults.set(data, forKey: SettingsKey.helmRepositories) }
    }
}

private extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
