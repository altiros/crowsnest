import Foundation
import Testing
@testable import CrowsnestKit

@Suite struct KubeConfigTests {
    let yaml = """
    apiVersion: v1
    kind: Config
    current-context: dev
    clusters:
    - name: dev-cluster
      cluster:
        server: https://10.0.0.1:6443
        certificate-authority: certs/ca.crt
        insecure-skip-tls-verify: false
    users:
    - name: dev-user
      user:
        token: abc123
    - name: eks
      user:
        exec:
          apiVersion: client.authentication.k8s.io/v1beta1
          command: aws
          args: [eks, get-token, --cluster-name, prod]
          env:
          - name: AWS_PROFILE
            value: prod
    contexts:
    - name: dev
      context:
        cluster: dev-cluster
        user: dev-user
        namespace: team-a
    - name: prod
      context:
        cluster: dev-cluster
        user: eks
    """

    @Test func parsesAndResolvesRelativePaths() throws {
        let config = try KubeConfig.parse(yaml, baseDirectory: URL(fileURLWithPath: "/home/me/.kube"))
        #expect(config.currentContext == "dev")
        #expect(config.contextNames == ["dev", "prod"])
        #expect(config.clusters[0].cluster.certificateAuthority == "/home/me/.kube/certs/ca.crt")
        #expect(config.users[1].user.exec?.args?.count == 4)
    }

    @Test func resolvesBearerAndExecAuth() throws {
        var config = try KubeConfig.parse(yaml)
        config.clusters[0].cluster.certificateAuthority = nil
        let dev = try config.connection(forContext: "dev")
        #expect(dev.auth == .bearer("abc123"))
        #expect(dev.defaultNamespace == "team-a")
        #expect(dev.server.absoluteString == "https://10.0.0.1:6443")
        let prod = try config.connection(forContext: "prod")
        guard case .exec(let exec) = prod.auth else { Issue.record("expected exec"); return }
        #expect(exec.command == "aws")
        #expect(exec.env?.first?.value == "prod")
    }

    @Test func mergeKeepsFirstDefinition() throws {
        var a = try KubeConfig.parse(yaml)
        var b = a
        b.currentContext = "prod"
        b.contexts[0].context.namespace = "other"
        b.contexts.append(.init(name: "extra", context: .init(cluster: "dev-cluster")))
        a.merge(b)
        #expect(a.currentContext == "dev")
        #expect(a.contexts.first { $0.name == "dev" }?.context.namespace == "team-a")
        #expect(a.contextNames == ["dev", "prod", "extra"])
    }

    @Test func missingContextThrows() throws {
        let config = try KubeConfig.parse(yaml)
        #expect(throws: KubeError.self) { try config.connection(forContext: "nope") }
    }
}

@Suite struct YAMLTests {
    @Test func roundTripKeepsTypes() throws {
        let value: JSONValue = [
            "apiVersion": "v1", "kind": "ConfigMap",
            "metadata": ["name": "x", "labels": ["version": "1.0", "enabled": "true", "empty": ""]],
            "data": ["script": "line1\nline2\n", "port": "8080", "flag": "yes"],
            "spec": ["replicas": 3, "ratio": .double(0.5), "on": true, "nothing": nil],
        ]
        let yaml = try value.yamlString()
        #expect(yaml.hasPrefix("apiVersion: v1\nkind: ConfigMap\nmetadata:"))
        #expect(yaml.contains("version: \"1.0\""))
        #expect(yaml.contains("replicas: 3\n"))
        let parsed = try JSONValue(yaml: yaml)
        #expect(parsed == value)
    }

    @Test func timestampsStayStrings() throws {
        let parsed = try JSONValue(yaml: "t: 2024-01-02T03:04:05Z\nn: 1.5")
        #expect(parsed["t"] == .string("2024-01-02T03:04:05Z"))
        #expect(parsed["n"] == .double(1.5))
    }
}

@Suite struct StatusTests {
    func pod(_ status: JSONValue, containers: Int = 1) -> KubeObject {
        let specContainers = JSONValue.array((0..<containers).map { _ in ["name": "c"] })
        return KubeObject(["kind": "Pod", "metadata": ["name": "p"], "spec": ["containers": specContainers], "status": status])
    }

    @Test func crashLoop() {
        let p = pod(["phase": "Running", "containerStatuses": [[
            "ready": false, "restartCount": 7, "state": ["waiting": ["reason": "CrashLoopBackOff"]],
        ]]])
        #expect(PodStatus.status(of: p) == ("CrashLoopBackOff", .error))
        #expect(PodStatus.restarts(of: p) == 7)
        #expect(PodStatus.readiness(of: p) == (0, 1))
    }

    @Test func runningAndInit() {
        let running = pod(["phase": "Running", "containerStatuses": [["ready": true, "state": ["running": [:]]]]])
        #expect(PodStatus.status(of: running) == ("Running", .ok))
        var initPod = pod(["phase": "Pending", "initContainerStatuses": [["state": ["running": [:]]]]])
        initPod.raw.set(.array([["name": "i"]]), at: ["spec", "initContainers"])
        #expect(PodStatus.status(of: initPod).text == "Init:0/1")
    }

    @Test func quantities() {
        #expect(Quantity.parse("250m") == 0.25)
        #expect(Quantity.parse("1Gi") == 1_073_741_824)
        #expect(Quantity.parse("12345678n")! > 0.0123)
        #expect(Quantity.formatCPU(0.25) == "250m")
        #expect(Quantity.formatCPU(0.0003) == "0.30m")
        #expect(Quantity.formatCPU(0.0042) == "4.2m")
        #expect(Quantity.formatCPU(0) == "0m")
        #expect(Quantity.formatCPU(1.5) == "1.50")
        #expect(Quantity.formatBytes(1_073_741_824) == "1.0 GiB")
    }

    @Test func ages() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(KubeDate.age(since: now.addingTimeInterval(-45), now: now) == "45s")
        #expect(KubeDate.age(since: now.addingTimeInterval(-3 * 86400 - 3600 * 5), now: now) == "3d5h")
        #expect(KubeDate.age(since: now.addingTimeInterval(-100 * 86400), now: now) == "100d")
        #expect(KubeDate.parse("2024-01-02T03:04:05Z") != nil)
        #expect(KubeDate.parse("2024-01-02T03:04:05.123456Z") != nil)
    }
}

@Suite struct ResourceKindTests {
    @Test func paths() {
        #expect(ResourceKind.pods.path(namespace: "a", name: "p", subresource: "log") == "/api/v1/namespaces/a/pods/p/log")
        #expect(ResourceKind.deployments.path() == "/apis/apps/v1/deployments")
        #expect(ResourceKind.nodes.path(namespace: "ignored", name: "n") == "/api/v1/nodes/n")
    }

    @Test func crdWithPrinterColumns() throws {
        let crd = KubeObject([
            "spec": [
                "group": "cert-manager.io", "scope": "Namespaced",
                "names": ["plural": "certificates", "kind": "Certificate"],
                "versions": [[
                    "name": "v1", "served": true, "storage": true,
                    "additionalPrinterColumns": [
                        ["name": "Ready", "type": "string", "jsonPath": #".status.conditions[?(@.type=="Ready")].status"#],
                        ["name": "Secret", "type": "string", "jsonPath": ".spec.secretName"],
                        ["name": "Hidden", "type": "string", "jsonPath": ".x", "priority": 1],
                    ],
                ]],
            ],
        ])
        let kind = try #require(ResourceKind(crd: crd))
        #expect(kind.path(namespace: "x") == "/apis/cert-manager.io/v1/namespaces/x/certificates")
        #expect(kind.columns.map(\.title) == ["Ready", "Secret"])
        let cert = KubeObject(["spec": ["secretName": "tls"], "status": ["conditions": [
            ["type": "Issuing", "status": "False"], ["type": "Ready", "status": "True"],
        ]]])
        #expect(kind.columns.map { $0.value(cert).display() } == ["True", "tls"])
    }

    @Test func jsonPathVariants() {
        let v: JSONValue = ["a": ["b": [["c": 1], ["c": 2]]], "x.y": "dotted"]
        #expect(JSONPath(".a.b[*].c").evaluate(v) == [1, 2])
        #expect(JSONPath(".a.b[-1].c").evaluate(v) == [2])
        #expect(JSONPath("{.a.b[0].c}").evaluate(v) == [1])
        #expect(JSONPath("['x.y']").evaluate(v) == ["dotted"])
    }

    @Test func selectors() {
        let d = KubeObject(["kind": "Deployment", "spec": ["selector": [
            "matchLabels": ["app": "web", "tier": "fe"],
            "matchExpressions": [["key": "env", "operator": "In", "values": ["a", "b"]]],
        ]]])
        #expect(WorkloadInfo.selector(of: d) == "app=web,tier=fe,env in (a,b)")
    }

    @Test func queryEncoding() throws {
        let client = try KubeClient(config: ConnectionConfig(contextName: "t", clusterName: "c", server: URL(string: "https://h:6443/prefix/")!))
        #expect(client.urlForTesting(path: "/api/v1/pods", query: ["labelSelector": "app in (a,b)"])
            == "https://h:6443/prefix/api/v1/pods?labelSelector=app%20in%20%28a%2Cb%29")
        Task { await client.shutdown() }
    }
}

@Suite struct ManifestTests {
    @Test func multiDocument() throws {
        let docs = try JSONValue.documents(yaml: """
        apiVersion: v1
        kind: ConfigMap
        metadata: {name: a}
        ---
        # comment only
        ---
        apiVersion: v1
        kind: Secret
        metadata:
          generateName: s-
        """)
        #expect(docs.count == 2)
        #expect(ManifestIssue.check(docs).isEmpty)
        let stream = try JSONValue.yamlStream(docs)
        #expect(try JSONValue.documents(yaml: stream) == docs)
    }

    @Test func syntaxErrorHasLine() {
        do {
            _ = try JSONValue.documents(yaml: "a: 1\nb:\n  - x\n  y: 2\n")
            Issue.record("expected error")
        } catch {
            #expect(error.line == 4)
            #expect(error.errorDescription?.hasPrefix("Line 4") == true)
        }
    }

    @Test func missingFields() {
        let issues = ManifestIssue.check([["kind": "Pod", "metadata": ["name": "x"]], "text"])
        #expect(issues == [.missingField(document: 1, field: "apiVersion"), .notAnObject(document: 2)])
    }
}

@Suite("Streaming")
struct StreamingTests {
    @Test func execStatusSuccess() {
        let (code, message) = ExecSession.parseStatus(Array(#"{"metadata":{},"status":"Success"}"#.utf8))
        #expect(code == 0)
        #expect(message == nil)
    }

    @Test func execStatusExitCode() {
        let json = #"{"status":"Failure","reason":"NonZeroExitCode","message":"command terminated with non-zero exit code","details":{"causes":[{"reason":"ExitCode","message":"3"}]}}"#
        let (code, message) = ExecSession.parseStatus(Array(json.utf8))
        #expect(code == 3)
        #expect(message == nil)
    }

    @Test func execStatusOtherFailure() {
        let (code, message) = ExecSession.parseStatus(Array(#"{"status":"Failure","message":"container not found"}"#.utf8))
        #expect(code == nil)
        #expect(message == "container not found")
    }

    @Test func serviceTargetPort() {
        let pod = KubeObject(["kind": "Pod", "metadata": ["name": "p"], "spec": ["containers": [
            ["name": "app", "ports": [["name": "http", "containerPort": 8080]]],
        ]]])
        #expect(KubeClient.containerPort(for: .int(9000), servicePort: 80, in: pod) == 9000)
        #expect(KubeClient.containerPort(for: "http", servicePort: 80, in: pod) == 8080)
        #expect(KubeClient.containerPort(for: "unknown", servicePort: 80, in: pod) == 80)
        #expect(KubeClient.containerPort(for: nil, servicePort: 80, in: pod) == 80)
    }
}

@Suite("Metrics")
struct MetricsTests {
    @Test func podResourceSpec() {
        let pod = KubeObject(["kind": "Pod", "metadata": ["name": "p"], "spec": ["containers": [
            ["name": "a", "resources": ["requests": ["cpu": "100m", "memory": "64Mi"], "limits": ["cpu": "500m", "memory": "128Mi"]]],
            ["name": "b", "resources": ["requests": ["cpu": "50m"], "limits": ["memory": "256Mi"]]],
        ]]])
        let spec = ResourceSpec.of(pod: pod)
        #expect(abs((spec.cpuRequest ?? 0) - 0.15) < 1e-9)
        #expect(spec.memoryRequest == Double(64 * 1024 * 1024))
        #expect(spec.cpuLimit == nil)  // container b has no CPU limit
        #expect(spec.memoryLimit == Double(384 * 1024 * 1024))
    }

    @Test func labelSelectors() {
        let labels = ["app": "web", "tier": "frontend"]
        #expect(LabelSelector.matches(["matchLabels": ["app": "web"]], labels: labels))
        #expect(!LabelSelector.matches(["matchLabels": ["app": "api"]], labels: labels))
        #expect(LabelSelector.matches(["app": "web"], labels: labels))  // service-style map
        #expect(LabelSelector.matches(["matchExpressions": [["key": "tier", "operator": "In", "values": ["frontend", "edge"]]]], labels: labels))
        #expect(!LabelSelector.matches(["matchExpressions": [["key": "tier", "operator": "NotIn", "values": ["frontend"]]]], labels: labels))
        #expect(LabelSelector.matches(["matchExpressions": [["key": "canary", "operator": "DoesNotExist"]]], labels: labels))
        #expect(!LabelSelector.matches([:], labels: labels))
        #expect(!LabelSelector.matches(nil, labels: labels))
    }

    @Test func meterSortsNumerically() {
        let small = CellValue.meter(value: 0.022, fraction: nil, text: "22m")
        let large = CellValue.meter(value: 1.5, fraction: 0.5, text: "1.50")
        #expect(CellValue.compare(small, large) == .orderedAscending)
        #expect(CellValue.compare(.meter(value: 0, fraction: nil, text: "0m"), .text("–")) == .orderedDescending)
        #expect(large.display() == "1.50 (50 %)")
    }
}

@Suite("Helm")
struct HelmTests {
    /// Builds a Secret like Helm 3 stores it: data.release = base64(base64(gzip(json))).
    static func secret(name: String, revision: Int, status: String, chartVersion: String, replicas: Int) throws -> KubeObject {
        let release: JSONValue = [
            "name": .string(name), "namespace": "web", "version": .int(Int64(revision)),
            "info": ["status": .string(status), "description": "Upgrade complete",
                     "last_deployed": "2026-11-08T08:00:00Z", "notes": "Visit http://example"],
            "chart": ["metadata": ["name": "nginx", "version": .string(chartVersion), "appVersion": "1.27.0"],
                      "values": ["replicaCount": 1, "image": ["repository": "nginx", "tag": "latest"]]],
            "config": ["replicaCount": .int(Int64(replicas)), "image": ["tag": "1.27"]],
            "manifest": .string("---\napiVersion: v1\nkind: Service\nmetadata:\n  name: \(name)\n---\napiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: \(name)\nspec:\n  replicas: \(replicas)\n"),
        ]
        let json = try release.jsonData()
        let deflate = try (json as NSData).compressed(using: .zlib) as Data
        var gzip = Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 3])
        gzip.append(deflate)
        gzip.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])  // CRC32 + size (not checked)
        let inner = gzip.base64EncodedString()
        return KubeObject([
            "apiVersion": "v1", "kind": "Secret", "type": "helm.sh/release.v1",
            "metadata": ["name": .string("sh.helm.release.v1.\(name).v\(revision)"), "namespace": "web",
                         "labels": ["owner": "helm", "name": .string(name), "status": .string(status), "version": .string(String(revision))]],
            "data": ["release": .string(Data(inner.utf8).base64EncodedString())],
        ])
    }

    @Test func decodesSecret() throws {
        let release = try #require(try HelmRelease.decode(Self.secret(name: "shop", revision: 2, status: "deployed", chartVersion: "18.1.0", replicas: 3)))
        #expect(release.name == "shop")
        #expect(release.revision == 2)
        #expect(release.chart == "nginx-18.1.0")
        #expect(release.appVersion == "1.27.0")
        #expect(release.statusTone == .ok)
        #expect(release.notes == "Visit http://example")
        #expect(release.resources.map(\.kind) == ["Service", "Deployment"])
        // User values override chart defaults, nested maps are merged.
        #expect(release.computedValues["replicaCount"] == .int(3))
        #expect(release.computedValues.value(at: "image.tag") == "1.27")
        #expect(release.computedValues.value(at: "image.repository") == "nginx")
    }

    @Test func latestRevisionPerRelease() throws {
        let revisions = try [
            HelmRelease.decode(Self.secret(name: "shop", revision: 1, status: "superseded", chartVersion: "18.0.0", replicas: 2)),
            HelmRelease.decode(Self.secret(name: "shop", revision: 2, status: "deployed", chartVersion: "18.1.0", replicas: 3)),
            HelmRelease.decode(Self.secret(name: "blog", revision: 1, status: "failed", chartVersion: "1.0.0", replicas: 1)),
        ].compactMap { $0 }
        let latest = KubeClient.latestRevisions(revisions)
        #expect(latest.map(\.name) == ["blog", "shop"])
        #expect(latest.first { $0.name == "shop" }?.revision == 2)
    }

    @Test func ignoresNonHelmObjects() throws {
        #expect(try HelmRelease.decode(KubeObject(["kind": "Secret", "metadata": ["name": "x"]])) == nil)
    }

    @Test func unifiedDiff() {
        let old = (1...10).map { "line \($0)" }.joined(separator: "\n")
        let new = old.replacingOccurrences(of: "line 5", with: "line five")
        let diff = TextDiff.unified(old: old, new: new, context: 1)
        #expect(diff == [.hunk("@@ -4 +4 @@"), .context("line 4"), .removed("line 5"), .added("line five"), .context("line 6")])
        #expect(TextDiff.unified(old: old, new: old).isEmpty)
    }
}
