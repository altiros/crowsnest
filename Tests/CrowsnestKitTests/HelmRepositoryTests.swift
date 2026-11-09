import Foundation
import Testing
@testable import CrowsnestKit

@Suite struct HelmRepositoryTests {
    let repo = HelmRepository(name: "example", url: "https://charts.example.com/stable")

    let index = """
    apiVersion: v1
    entries:
      web:
      - name: web
        version: 1.9.0
        appVersion: 1.10
        description: Old
        created: "2026-01-01T10:00:00.123456789Z"
        urls: [web-1.9.0.tgz]
      - name: web
        version: 1.10.0
        appVersion: "2.0"
        description: A web server
        created: "2026-08-19T11:35:24.161353595Z"
        home: https://example.com
        keywords: [http, server]
        maintainers:
        - name: alice
        urls: [https://cdn.example.com/web-1.10.0.tgz]
      - name: web
        version: 1.10.0-rc.1
        urls: [web-1.10.0-rc.1.tgz]
      api:
      - name: api
        version: 0.1.0
        deprecated: true
        urls: [charts/api-0.1.0.tgz]
    generated: "2026-08-19T11:35:24Z"
    """

    @Test func parsesIndexNewestFirst() throws {
        let charts = try HelmRepositories.parseIndex(index, repository: repo)
        #expect(charts.map(\.name) == ["api", "web"])
        let web = try #require(charts.first { $0.name == "web" })
        #expect(web.versions.map(\.version) == ["1.10.0", "1.10.0-rc.1", "1.9.0"])
        #expect(web.latest.appVersion == "2.0")
        #expect(web.latest.keywords == ["http", "server"])
        #expect(web.latest.maintainers == ["alice"])
        #expect(web.latest.created != nil)
        #expect(web.versions[2].created != nil)
        #expect(charts.first { $0.name == "api" }?.latest.deprecated == true)
    }

    @Test func keepsVersionStringsVerbatim() throws {
        let web = try #require(try HelmRepositories.parseIndex(index, repository: repo).first { $0.name == "web" })
        #expect(web.versions.last?.appVersion == "1.10")  // not 1.1
    }

    @Test func resolvesArchiveURLs() throws {
        let charts = try HelmRepositories.parseIndex(index, repository: repo)
        let web = try #require(charts.first { $0.name == "web" })
        #expect(HelmRepositories.archiveURL(of: web.latest, in: repo)?.absoluteString == "https://cdn.example.com/web-1.10.0.tgz")
        #expect(HelmRepositories.archiveURL(of: web.versions[2], in: repo)?.absoluteString == "https://charts.example.com/stable/web-1.9.0.tgz")
        let api = try #require(charts.first { $0.name == "api" })
        #expect(HelmRepositories.archiveURL(of: api.latest, in: repo)?.absoluteString == "https://charts.example.com/stable/charts/api-0.1.0.tgz")
    }

    @Test func semverOrder() {
        #expect(SemVer.isNewer("1.10.0", than: "1.9.9"))
        #expect(SemVer.isNewer("v2.0.0", than: "1.99.0"))
        #expect(SemVer.isNewer("1.0.0", than: "1.0.0-rc.2"))
        #expect(SemVer.isNewer("1.0.0-rc.10", than: "1.0.0-rc.2"))
        #expect(SemVer.compare("1.0.0+build.1", "1.0.0") == .orderedSame)
    }

    @Test func parsesHelmRepositoriesFile() throws {
        let yaml = """
        apiVersion: ""
        repositories:
        - name: metrics-server
          url: https://kubernetes-sigs.github.io/metrics-server/
          password: ""
        - name: registry
          url: oci://ghcr.io/example
        """
        #expect(try HelmRepositories.parseRepositoriesFile(yaml) == [
            HelmRepository(name: "metrics-server", url: "https://kubernetes-sigs.github.io/metrics-server/"),
        ])
    }

    @Test func helmConfigLocations() {
        let home = URL(fileURLWithPath: "/Users/me")
        let paths = HelmRepositories.helmCLIConfigCandidates(environment: ["HELM_REPOSITORY_CONFIG": "/tmp/repos.yaml"], home: home).map(\.path)
        #expect(paths.first == "/tmp/repos.yaml")
        #expect(paths.contains("/Users/me/Library/Preferences/helm/repositories.yaml"))
    }

    @Test func validatesNewRepositories() {
        #expect(HelmRepository.validate(name: "", url: "https://x.io", existing: []) != nil)
        #expect(HelmRepository.validate(name: "a b", url: "https://x.io", existing: []) != nil)
        #expect(HelmRepository.validate(name: "x", url: "oci://ghcr.io/x", existing: []) != nil)
        #expect(HelmRepository.validate(name: "x", url: "ftp://x.io", existing: []) != nil)
        #expect(HelmRepository.validate(name: "example", url: "https://x.io", existing: [repo]) != nil)
        #expect(HelmRepository.validate(name: "bitnami", url: "https://charts.bitnami.com/bitnami", existing: [repo]) == nil)
        #expect(repo.indexURL?.absoluteString == "https://charts.example.com/stable/index.yaml")
    }

    // MARK: Archives

    /// Builds a ustar archive (regular files) for tests.
    static func tar(_ files: [(String, String)], paxPath: String? = nil) -> Data {
        var out = [UInt8]()
        func header(name: String, size: Int, type: UInt8) {
            var h = [UInt8](repeating: 0, count: 512)
            func put(_ s: String, _ at: Int) { for (i, b) in Array(s.utf8).enumerated() { h[at + i] = b } }
            put(String(name.prefix(100)), 0)
            put("0000644", 100)
            put(String(format: "%011o", size), 124)
            h[156] = type
            put("ustar", 257)
            put("00", 263)
            for i in 148..<156 { h[i] = 0x20 }
            let sum = h.reduce(0) { $0 + Int($1) }
            put(String(format: "%06o", sum), 148)
            h[154] = 0
            out += h
        }
        func body(_ bytes: [UInt8]) {
            out += bytes
            out += [UInt8](repeating: 0, count: (512 - bytes.count % 512) % 512)
        }
        if let paxPath {
            let record = " path=\(paxPath)\n"
            let full = "\(record.utf8.count + 3)\(record)"  // length prefix incl. itself (2 digits + record)
            header(name: "PaxHeader", size: full.utf8.count, type: UInt8(ascii: "x"))
            body(Array(full.utf8))
        }
        for (name, content) in files {
            header(name: name, size: content.utf8.count, type: UInt8(ascii: "0"))
            body(Array(content.utf8))
        }
        out += [UInt8](repeating: 0, count: 1024)
        return Data(out)
    }

    @Test func readsChartFilesFromTar() throws {
        let archive = Self.tar([
            ("web/Chart.yaml", "name: web\nversion: 1.10.0\n"),
            ("web/values.yaml", "replicaCount: 1\n"),
            ("web/README.md", "# Web\n"),
            ("web/charts/sub/values.yaml", "sub: true\n"),
            ("web/templates/deployment.yaml", "kind: Deployment\n"),
        ])
        let files = try HelmRepositories.chartFiles(fromArchive: archive, chartName: "web")
        #expect(files.values == "replicaCount: 1\n")
        #expect(files.readme == "# Web\n")
        #expect(files.chartYAML?.contains("version: 1.10.0") == true)
    }

    @Test func paxLongNames() {
        let long = "web/" + String(repeating: "x", count: 120) + ".yaml"
        let files = Tar.files(Self.tar([("ignored-short-name", "content")], paxPath: long))
        #expect(files[long] == Data("content".utf8))
    }

    @Test func doublyCompressedArchive() throws {
        let tgz = try #require(Self.gzip(Self.tar([("web/Chart.yaml", "name: web\n"), ("web/values.yaml", "a: 1\n")])))
        let twice = try #require(Self.gzip(tgz))
        #expect(try HelmRepositories.chartFiles(fromArchive: twice, chartName: "web").values == "a: 1\n")
    }

    @Test func rejectsNonChartDownloads() {
        #expect(throws: KubeError.self) { try HelmRepositories.chartFiles(fromArchive: Data("<html>404</html>".utf8), chartName: "web") }
    }

    @Test func ociReferences() throws {
        let ref = try #require(OCIRegistry.parse(URL(string: "oci://registry-1.docker.io/bitnamicharts/airflow:25.0.2")!))
        #expect(ref == .init(host: "registry-1.docker.io", repository: "bitnamicharts/airflow", tag: "25.0.2"))
        #expect(OCIRegistry.parse(URL(string: "oci://localhost:5000/charts/web")!)?.host == "localhost:5000")
        let p = OCIRegistry.challengeParameters(#"Bearer realm="https://auth.docker.io/token",service="registry.docker.io",scope="repository:bitnamicharts/airflow:pull""#)
        #expect(p["realm"] == "https://auth.docker.io/token")
        #expect(p["service"] == "registry.docker.io")
        #expect(p["scope"] == "repository:bitnamicharts/airflow:pull")
    }

    /// gzip via the system tool (tests only).
    static func gzip(_ data: Data) -> Data? {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "f")
        try? data.write(to: file)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        p.arguments = ["-n", file.path]
        try? p.run(); p.waitUntilExit()
        return try? Data(contentsOf: dir.appending(path: "f.gz"))
    }
}
