import CrowsnestKit
import Foundation
import Testing
@testable import CrowsnestUI

@Suite @MainActor struct HelmCatalogTests {
    func catalog() -> HelmCatalog {
        let defaults = UserDefaults(suiteName: "crowsnest-tests-\(UUID().uuidString)")!
        return HelmCatalog(defaults: defaults)
    }

    func version(_ urls: [String]) -> HelmChartVersion {
        HelmChartVersion(name: "web", version: "1.2.3", appVersion: "", description: "", created: nil, urls: urls, icon: nil,
                         home: nil, sources: [], keywords: [], maintainers: [], deprecated: false, kubeVersion: nil, type: nil)
    }

    @Test func installCommandAddsUnknownRepository() {
        let repo = HelmRepository(name: "example", url: "https://charts.example.com")
        let cmd = catalog().installCommand(for: version(["web-1.2.3.tgz"]), in: repo, namespace: "apps")
        #expect(cmd == "helm repo add example https://charts.example.com && helm install web example/web --version 1.2.3 --namespace apps --create-namespace")
    }

    @Test func installCommandForOCICharts() {
        let repo = HelmRepository(name: "bitnami", url: "https://charts.bitnami.com/bitnami")
        let cmd = catalog().installCommand(for: version(["oci://registry-1.docker.io/bitnamicharts/web:1.2.3"]), in: repo, namespace: nil)
        #expect(cmd == "helm install web oci://registry-1.docker.io/bitnamicharts/web --version 1.2.3")
    }

    @Test func addValidatesAndPersists() {
        let defaults = UserDefaults(suiteName: "crowsnest-tests-\(UUID().uuidString)")!
        let c = HelmCatalog(defaults: defaults)
        #expect(c.add(name: "", url: "https://x.io") != nil)
        #expect(c.add(name: "myrepo", url: "https://127.0.0.1:1/charts") == nil)
        #expect(HelmCatalog(defaults: defaults).userRepositories.map(\.name) == ["myrepo"])
        c.remove(HelmRepository(name: "myrepo", url: "https://127.0.0.1:1/charts"))
        #expect(HelmCatalog(defaults: defaults).userRepositories.isEmpty)
    }

    @Test func markdownBlocks() {
        let blocks = MarkdownText.blocks("""
        # Title
        Some **bold** text
        continued.

        ```console
        helm install x
        ```
        ## Next
        """)
        #expect(blocks == [.heading(1, "Title"), .paragraph("Some **bold** text\ncontinued."), .code("helm install x"), .heading(2, "Next")])
    }

    @Test func markdownHidesHTMLComments() {
        #expect(MarkdownText.blocks("<!--- app-name: X -->\n# Title") == [.heading(1, "Title")])
    }
}
