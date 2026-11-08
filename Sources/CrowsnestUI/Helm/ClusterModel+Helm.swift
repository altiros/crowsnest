import CrowsnestKit
import Foundation

extension ClusterModel {
    /// Latest revision of each release, filtered by the search text.
    public var helmReleases: [HelmRelease] {
        var latest: [String: HelmRelease] = [:]
        for r in helmRevisions where (latest[r.releaseKey]?.revision ?? -1) < r.revision { latest[r.releaseKey] = r }
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return latest.values
            .filter { query.isEmpty || $0.name.lowercased().contains(query) || $0.chartName.lowercased().contains(query) }
            .sorted { ($0.namespace, $0.name) < ($1.namespace, $1.name) }
    }

    public var selectedHelmRelease: HelmRelease? {
        // The table selects by `id` ("ns/name#revision"); match the release regardless of revision.
        guard let key = selectedHelmReleaseKey?.split(separator: "#").first.map(String.init) else { return nil }
        return helmReleases.first { $0.releaseKey == key }
    }

    /// All revisions of one release, newest first.
    public func helmHistory(of release: HelmRelease) -> [HelmRelease] {
        helmRevisions.filter { $0.releaseKey == release.releaseKey }.sorted { $0.revision > $1.revision }
    }

    public func loadHelm() async {
        guard let client else { return }
        do {
            let revisions = try await client.helmRevisions(namespace: namespace)
            helmRevisions = revisions
            helmError = nil
            lastRefresh = .now
        } catch {
            helmError = error.localizedDescription
        }
    }

    /// Opens a resource rendered by a release.
    public func reveal(_ ref: HelmRelease.ResourceRef, of release: HelmRelease) {
        reveal(kindName: ref.kind, apiVersion: ref.apiVersion, name: ref.name, namespace: ref.namespace ?? release.namespace)
    }
}
