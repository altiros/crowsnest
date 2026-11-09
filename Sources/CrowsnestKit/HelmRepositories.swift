import Foundation
import Yams

/// A classic Helm chart repository (an HTTP(S) server with an `index.yaml`). OCI registries aren't indexable
/// and are not supported here.
public struct HelmRepository: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var url: String
    public var id: String { name }

    public init(name: String, url: String) {
        self.name = name
        self.url = url
    }

    /// `index.yaml` of the repository.
    public var indexURL: URL? {
        URL(string: url.hasSuffix("/") ? url + "index.yaml" : url + "/index.yaml")
    }

    /// Validates user input; returns an error message or `nil`.
    public static func validate(name: String, url: String, existing: [HelmRepository]) -> String? {
        let name = name.trimmingCharacters(in: .whitespaces), url = url.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return "Enter a name." }
        if name.contains(where: { $0.isWhitespace || $0 == "/" }) { return "The name must not contain spaces or slashes." }
        if existing.contains(where: { $0.name == name }) { return "A repository named \"\(name)\" already exists." }
        if url.hasPrefix("oci://") { return "OCI registries have no chart index and can't be browsed." }
        guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(), ["http", "https"].contains(scheme),
              parsed.host != nil else { return "Enter an http(s) URL." }
        return nil
    }
}

/// One version of a chart, as listed in a repository index.
public struct HelmChartVersion: Sendable, Hashable, Identifiable {
    public var name: String
    public var version: String
    public var appVersion: String
    public var description: String
    public var created: Date?
    public var urls: [String]
    public var icon: String?
    public var home: String?
    public var sources: [String]
    public var keywords: [String]
    public var maintainers: [String]
    public var deprecated: Bool
    public var kubeVersion: String?
    public var type: String?

    public var id: String { "\(name)@\(version)" }

    public init(name: String, version: String, appVersion: String = "", description: String = "", created: Date? = nil,
                urls: [String] = [], icon: String? = nil, home: String? = nil, sources: [String] = [], keywords: [String] = [],
                maintainers: [String] = [], deprecated: Bool = false, kubeVersion: String? = nil, type: String? = nil) {
        self.name = name
        self.version = version
        self.appVersion = appVersion
        self.description = description
        self.created = created
        self.urls = urls
        self.icon = icon
        self.home = home
        self.sources = sources
        self.keywords = keywords
        self.maintainers = maintainers
        self.deprecated = deprecated
        self.kubeVersion = kubeVersion
        self.type = type
    }
}

/// A chart of a repository with all its versions (newest first).
public struct HelmChart: Sendable, Hashable, Identifiable {
    public var repository: HelmRepository
    public var name: String
    public var versions: [HelmChartVersion]

    public var id: String { "\(repository.name)/\(name)" }
    public var latest: HelmChartVersion { versions[0] }

    /// `versions` must not be empty and should be sorted newest first.
    public init(repository: HelmRepository, name: String, versions: [HelmChartVersion]) {
        self.repository = repository
        self.name = name
        self.versions = versions
    }
}

/// Files of a downloaded chart archive that are shown to the user.
public struct HelmChartFiles: Sendable, Equatable {
    public var readme: String?
    public var values: String?
    public var chartYAML: String?
}

public enum HelmRepositories {
    // MARK: Helm CLI configuration

    /// Repositories configured for the `helm` CLI on this machine (read-only), e.g. from `helm repo add`.
    public static func helmCLIRepositories(environment: [String: String] = ProcessInfo.processInfo.environment,
                                           home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> [HelmRepository] {
        for url in helmCLIConfigCandidates(environment: environment, home: home) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            return (try? parseRepositoriesFile(text)) ?? []
        }
        return []
    }

    static func helmCLIConfigCandidates(environment: [String: String], home: URL) -> [URL] {
        var result: [URL] = []
        if let path = environment["HELM_REPOSITORY_CONFIG"], !path.isEmpty { result.append(URL(fileURLWithPath: path)) }
        if let config = environment["HELM_CONFIG_HOME"], !config.isEmpty {
            result.append(URL(fileURLWithPath: config).appending(path: "repositories.yaml"))
        }
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            result.append(URL(fileURLWithPath: xdg).appending(path: "helm/repositories.yaml"))
        }
        result.append(home.appending(path: "Library/Preferences/helm/repositories.yaml"))  // macOS default
        result.append(home.appending(path: ".config/helm/repositories.yaml"))  // Linux default
        return result
    }

    /// Parses Helm's `repositories.yaml` (name + URL only; credentials are ignored).
    public static func parseRepositoriesFile(_ yaml: String) throws -> [HelmRepository] {
        guard let root = try Yams.compose(yaml: yaml), let repos = root["repositories"]?.sequence else { return [] }
        return repos.compactMap { node in
            guard let name = node["name"]?.string, let url = node["url"]?.string, !url.hasPrefix("oci://") else { return nil }
            return HelmRepository(name: name, url: url)
        }
    }

    // MARK: Index

    /// Parses a repository `index.yaml`. Values are taken verbatim (a version like `1.10` stays "1.10").
    public static func parseIndex(_ yaml: String, repository: HelmRepository) throws -> [HelmChart] {
        guard let root = try Yams.compose(yaml: yaml) else { return [] }
        guard let entries = root["entries"]?.mapping else {
            throw KubeError.invalidInput("\(repository.name): index.yaml has no entries")
        }
        var charts: [HelmChart] = []
        for (key, value) in entries {
            guard let name = key.string, let list = value.sequence else { continue }
            let versions = list.compactMap { chartVersion($0, name: name) }
                .sorted { SemVer.isNewer($0.version, than: $1.version) }
            guard !versions.isEmpty else { continue }
            charts.append(HelmChart(repository: repository, name: name, versions: versions))
        }
        return charts.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func chartVersion(_ node: Node, name: String) -> HelmChartVersion? {
        guard let version = node["version"]?.string else { return nil }
        func strings(_ key: String) -> [String] { node[key]?.sequence?.compactMap(\.string) ?? [] }
        return HelmChartVersion(
            name: name,
            version: version,
            appVersion: node["appVersion"]?.string ?? "",
            description: node["description"]?.string ?? "",
            created: node["created"]?.string.flatMap(KubeDate.parse),
            urls: strings("urls"),
            icon: node["icon"]?.string,
            home: node["home"]?.string,
            sources: strings("sources"),
            keywords: strings("keywords"),
            maintainers: node["maintainers"]?.sequence?.compactMap { $0["name"]?.string } ?? [],
            deprecated: node["deprecated"]?.string == "true",
            kubeVersion: node["kubeVersion"]?.string,
            type: node["type"]?.string
        )
    }

    /// Downloads and parses a repository index.
    public static func fetchIndex(_ repository: HelmRepository, session: URLSession = .shared) async throws -> [HelmChart] {
        guard let url = repository.indexURL else { throw KubeError.invalidInput("\(repository.name): invalid URL") }
        let data = try await download(url, session: session, what: "\(repository.name) index")
        let text = String(decoding: data, as: UTF8.self)
        // Parsing large indexes takes a moment – keep it off the caller's actor.
        return try await Task.detached(priority: .userInitiated) {
            try parseIndex(text, repository: repository)
        }.value
    }

    // MARK: Chart archives

    /// Absolute URL of a chart archive (`urls` in the index may be relative to the repository URL).
    public static func archiveURL(of version: HelmChartVersion, in repository: HelmRepository) -> URL? {
        guard let first = version.urls.first else { return nil }
        if let absolute = URL(string: first), absolute.scheme != nil { return absolute }
        let base = repository.url.hasSuffix("/") ? repository.url : repository.url + "/"
        return URL(string: first, relativeTo: URL(string: base))?.absoluteURL
    }

    /// Downloads a chart archive and returns its README, default values and Chart.yaml.
    public static func fetchChartFiles(_ version: HelmChartVersion, in repository: HelmRepository,
                                       session: URLSession = .shared) async throws -> HelmChartFiles {
        guard let url = archiveURL(of: version, in: repository) else {
            throw KubeError.invalidInput("\(version.name) \(version.version) has no download URL")
        }
        let what = "\(version.name)-\(version.version).tgz"
        let archive = url.scheme == "oci"
            ? try await OCIRegistry.pullChart(url, session: session)
            : try await download(url, session: session, what: what, headers: ["Accept-Encoding": "identity"])
        return try chartFiles(fromArchive: archive, chartName: version.name)
    }

    static func chartFiles(fromArchive archive: Data, chartName: String) throws -> HelmChartFiles {
        // Some servers compress the .tgz once more on the way (Content-Encoding) – unwrap every gzip layer.
        var tar = archive
        for _ in 0..<3 where Gzip.isGzip(tar) { tar = try Gzip.decompress(tar) }
        let files = Tar.files(tar)
        guard files.keys.contains(where: { $0.hasSuffix("/Chart.yaml") }) else {
            throw KubeError.invalidInput("The download of \(chartName) is not a chart archive")
        }
        // Files live in "<chart>/…"; ignore files of subcharts ("<chart>/charts/<sub>/…").
        func file(_ name: String) -> String? {
            let match = files.first { path, _ in
                let parts = path.split(separator: "/")
                return parts.count == 2 && parts[1].caseInsensitiveCompare(name) == .orderedSame
            }
            return match.map { String(decoding: $0.value, as: UTF8.self) }
        }
        return HelmChartFiles(readme: file("README.md"), values: file("values.yaml"), chartYAML: file("Chart.yaml"))
    }

    static func download(_ url: URL, session: URLSession, what: String, headers: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Crowsnest", forHTTPHeaderField: "User-Agent")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.timeoutInterval = 60
        for attempt in 1...3 {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return data }
            // Gateway errors (e.g. GitHub release downloads) are often transient – retry a couple of times.
            if [502, 503, 504].contains(http.statusCode), attempt < 3 {
                try await Task.sleep(for: .seconds(Double(attempt)))
                continue
            }
            throw KubeError.invalidInput("Downloading \(what) failed: HTTP \(http.statusCode)")
        }
        throw KubeError.invalidInput("Downloading \(what) failed")
    }
}

/// Anonymous access to OCI/Docker registries: pulling Helm charts stored as OCI artifacts
/// (e.g. `oci://registry-1.docker.io/bitnamicharts/nginx:18.0.0`) and listing image tags.
public enum OCIRegistry {
    static let chartLayerType = "application/vnd.cncf.helm.chart.content.v1.tar+gzip"

    public struct Reference: Equatable, Sendable {
        public var host: String, repository: String, tag: String
        /// Set for digest-pinned references (`image@sha256:…`).
        public var digest: String?

        public init(host: String, repository: String, tag: String, digest: String? = nil) {
            self.host = host
            self.repository = repository
            self.tag = tag
            self.digest = digest
        }
    }

    /// Parses a container image reference like kubectl does: `nginx:1.27` → registry-1.docker.io/library/nginx,
    /// `ghcr.io/org/app:1.2`, `registry.local:5000/app@sha256:…`.
    public static func parseImage(_ image: String) -> Reference? {
        var rest = image.trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        var digest: String?
        if let at = rest.firstIndex(of: "@") { digest = String(rest[rest.index(after: at)...]); rest = String(rest[..<at]) }
        var tag = "latest"
        if let colon = rest.lastIndex(of: ":"), !rest[colon...].contains("/") {
            tag = String(rest[rest.index(after: colon)...])
            rest = String(rest[..<colon])
        }
        var parts = rest.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return nil }
        var host = "registry-1.docker.io"
        if parts.count > 1, parts[0].contains(".") || parts[0].contains(":") || parts[0] == "localhost" {
            host = parts.removeFirst()
            if host == "docker.io" || host == "index.docker.io" { host = "registry-1.docker.io" }
        }
        if host == "registry-1.docker.io" && parts.count == 1 { parts.insert("library", at: 0) }
        return Reference(host: host, repository: parts.joined(separator: "/"), tag: tag, digest: digest)
    }

    /// All tags of a repository (follows pagination, at most `maxPages` pages).
    public static func tags(of ref: Reference, session: URLSession = .shared, maxPages: Int = 20) async throws -> [String] {
        var token: String?
        var url: String? = "https://\(ref.host)/v2/\(ref.repository)/tags/list?n=1000"
        var result: [String] = []
        var pages = 0
        while let next = url, pages < maxPages {
            pages += 1
            let (data, link) = try await getWithLink(next, accept: "application/json", token: &token, session: session)
            result += (try JSONValue(jsonData: data))["tags"]?.array?.compactMap(\.string) ?? []
            // Link: </v2/library/nginx/tags/list?last=1.2&n=1000>; rel="next"
            url = link.flatMap { header in
                guard let start = header.firstIndex(of: "<"), let end = header.firstIndex(of: ">"), header.contains("rel=\"next\"") else { return nil }
                let path = String(header[header.index(after: start)..<end])
                return path.hasPrefix("http") ? path : "https://\(ref.host)\(path)"
            }
        }
        return result
    }

    static func parse(_ url: URL) -> Reference? {
        guard url.scheme == "oci", let host = url.host else { return nil }
        var path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var tag = "latest"
        if let colon = path.lastIndex(of: ":") { tag = String(path[path.index(after: colon)...]); path = String(path[..<colon]) }
        let port = url.port.map { ":\($0)" } ?? ""
        return path.isEmpty ? nil : Reference(host: host + port, repository: path, tag: tag)
    }

    static func pullChart(_ url: URL, session: URLSession) async throws -> Data {
        guard let ref = parse(url) else { throw KubeError.invalidInput("Invalid OCI reference \(url.absoluteString)") }
        let base = "https://\(ref.host)/v2/\(ref.repository)"
        var token: String?
        let manifestData = try await get("\(base)/manifests/\(ref.tag)", accept: "application/vnd.oci.image.manifest.v1+json",
                                         token: &token, session: session)
        let manifest = try JSONValue(jsonData: manifestData)
        guard let layer = manifest["layers"]?.array?.first(where: { $0["mediaType"]?.string == chartLayerType }),
              let digest = layer["digest"]?.string else {
            throw KubeError.invalidInput("\(ref.repository):\(ref.tag) is not a Helm chart")
        }
        return try await get("\(base)/blobs/\(digest)", accept: "*/*", token: &token, session: session)
    }

    static func get(_ urlString: String, accept: String, token: inout String?, session: URLSession) async throws -> Data {
        try await getWithLink(urlString, accept: accept, token: &token, session: session).data
    }

    /// GET with the registry's anonymous bearer-token flow (401 → token from the `WWW-Authenticate` realm → retry).
    static func getWithLink(_ urlString: String, accept: String, token: inout String?, session: URLSession) async throws -> (data: Data, link: String?) {
        guard let url = URL(string: urlString) else { throw KubeError.invalidInput("Invalid URL \(urlString)") }
        for attempt in 0..<2 {
            var request = URLRequest(url: url)
            request.setValue(accept, forHTTPHeaderField: "Accept")
            request.setValue("Crowsnest", forHTTPHeaderField: "User-Agent")
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return (data, nil) }
            if http.statusCode == 401, attempt == 0, let challenge = http.value(forHTTPHeaderField: "WWW-Authenticate") {
                token = try await fetchToken(challenge: challenge, session: session)
                continue
            }
            guard (200..<300).contains(http.statusCode) else {
                throw KubeError.invalidInput(http.statusCode == 401 || http.statusCode == 403
                    ? "The registry requires a login" : "Registry request failed: HTTP \(http.statusCode) for \(url.lastPathComponent)")
            }
            return (data, http.value(forHTTPHeaderField: "Link"))
        }
        throw KubeError.invalidInput("The registry requires a login")
    }

    /// `Bearer realm="https://auth.docker.io/token",service="registry.docker.io",scope="repository:x:pull"`
    static func challengeParameters(_ header: String) -> [String: String] {
        var result: [String: String] = [:]
        let body = header.drop { $0 != " " }
        for part in body.split(separator: ",") {
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            result[pair[0].trimmingCharacters(in: .whitespaces)] = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        }
        return result
    }

    static func fetchToken(challenge: String, session: URLSession) async throws -> String {
        let params = challengeParameters(challenge)
        guard challenge.lowercased().hasPrefix("bearer"), let realm = params["realm"], var components = URLComponents(string: realm) else {
            throw KubeError.invalidInput("The registry requires a login")
        }
        components.queryItems = ["service", "scope"].compactMap { key in params[key].map { URLQueryItem(name: key, value: $0) } }
        guard let url = components.url else { throw KubeError.invalidInput("Invalid token URL") }
        let data = try await HelmRepositories.download(url, session: session, what: "registry token")
        let json = try JSONValue(jsonData: data)
        guard let token = json["token"]?.string ?? json["access_token"]?.string else {
            throw KubeError.invalidInput("The registry returned no token")
        }
        return token
    }
}

/// Orders version strings like Helm (SemVer, pre-releases before releases).
public enum SemVer {
    public static func isNewer(_ a: String, than b: String) -> Bool { compare(a, b) == .orderedDescending }

    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let (ca, pa) = split(a), (cb, pb) = split(b)
        for i in 0..<max(ca.count, cb.count) {
            let x = i < ca.count ? ca[i] : 0, y = i < cb.count ? cb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        switch (pa, pb) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending  // 1.0.0 > 1.0.0-rc1
        case (_, nil): return .orderedAscending
        case let (x?, y?): return x.localizedStandardCompare(y)
        }
    }

    /// Numeric components and pre-release part ("v1.2.3-rc.1" → [1, 2, 3], "rc.1").
    public static func split(_ version: String) -> ([Int], String?) {
        var v = version.trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("v") { v.removeFirst() }
        if let plus = v.firstIndex(of: "+") { v = String(v[..<plus]) }  // build metadata doesn't order
        let pre: String?
        if let dash = v.firstIndex(of: "-") { pre = String(v[v.index(after: dash)...]); v = String(v[..<dash]) } else { pre = nil }
        return (v.split(separator: ".").map { Int($0) ?? 0 }, pre)
    }
}

/// Minimal reader for (ustar/pax/GNU) tar archives: regular files only.
enum Tar {
    static func files(_ data: Data) -> [String: Data] {
        let bytes = [UInt8](data)
        var result: [String: Data] = [:]
        var offset = 0
        var nextName: String?  // from a pax 'x' or GNU 'L' header
        while offset + 512 <= bytes.count {
            let header = bytes[offset..<(offset + 512)]
            if header.allSatisfy({ $0 == 0 }) { break }
            func field(_ start: Int, _ length: Int) -> String {
                let slice = bytes[(offset + start)..<(offset + start + length)]
                return String(decoding: slice.prefix { $0 != 0 }, as: UTF8.self)
            }
            let size = Int(field(124, 12).trimmingCharacters(in: .whitespaces), radix: 8) ?? 0
            let type = bytes[offset + 156]
            var name = field(0, 100)
            if field(257, 5) == "ustar" {
                let prefix = field(345, 155)
                if !prefix.isEmpty { name = prefix + "/" + name }
            }
            let start = offset + 512, end = min(start + size, bytes.count)
            let content = Data(bytes[start..<end])
            switch type {
            case UInt8(ascii: "x"):  // pax extended header: "<len> path=<value>\n"
                nextName = paxPath(content)
            case UInt8(ascii: "L"):  // GNU long name
                nextName = String(decoding: content.prefix { $0 != 0 }, as: UTF8.self)
            case 0, UInt8(ascii: "0"):
                result[nextName ?? name] = content
                nextName = nil
            default:
                nextName = nil
            }
            offset = start + (size + 511) / 512 * 512
        }
        return result
    }

    static func paxPath(_ data: Data) -> String? {
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let space = line.firstIndex(of: " ") else { continue }
            let record = line[line.index(after: space)...]
            if record.hasPrefix("path=") { return String(record.dropFirst(5)) }
        }
        return nil
    }
}
