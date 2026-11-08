import Foundation
import CrowsnestKit

// Read-only smoke test against a real cluster:
//   swift run crowsnest-probe [context]
let config = try KubeConfig.load(from: KubeConfig.defaultFileURLs())
let contextName = CommandLine.arguments.dropFirst().first ?? config.currentContext ?? config.contextNames.first ?? ""
print("Contexts: \(config.contextNames.joined(separator: ", "))")
print("Using: \(contextName)")

let client = try await KubeClientPool.shared.client(for: config.connection(forContext: contextName))
let version = try await client.serverVersion()
print("Server: \(version.gitVersion) \(version.platform)")

for kind in [ResourceKind.nodes, .namespaces, .pods, .deployments, .services, .customResourceDefinitions] {
    let start = Date()
    let items = try await client.list(kind)
    print(String(format: "%-28@ %5d  (%.0f ms)", kind.title as NSString, items.count, Date().timeIntervalSince(start) * 1000))
}
let pods = try await client.list(.pods)
for pod in pods.prefix(5) {
    let row = ResourceKind.pods.allColumns.map { $0.value(pod).display() }
    print("  " + row.joined(separator: " | "))
}
if let pod = pods.first(where: { PodStatus.status(of: $0).text == "Running" }) {
    let log = try await client.logs(pod: pod.name, namespace: pod.namespace!, options: .init(tailLines: 3))
    print("Logs \(pod.name):\n\(log)")
    print(try pod.cleanedForDisplay.yamlString().split(separator: "\n").prefix(12).joined(separator: "\n"))
}
let crdKinds = try await client.customResourceKinds()
print("CRD kinds: \(crdKinds.count), e.g. \(crdKinds.prefix(3).map(\.id))")
if let metrics = try await client.nodeMetrics() {
    for (node, u) in metrics.sorted(by: { $0.key < $1.key }) {
        print("  \(node): CPU \(Quantity.formatCPU(u.cpu)), RAM \(Quantity.formatBytes(u.memory))")
    }
} else {
    print("metrics-server not available")
}

// Server-side apply as a dry run (validated by the API server, nothing is persisted).
let manifests = try JSONValue.documents(yaml: """
apiVersion: v1
kind: ConfigMap
metadata:
  name: crowsnest-probe-dryrun
data:
  hello: world
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: crowsnest-probe-dryrun
spec:
  secretName: crowsnest-probe-dryrun
  dnsNames: [example.invalid]
  issuerRef: {name: does-not-matter, kind: ClusterIssuer}
""")
for manifest in manifests {
    do {
        let r = try await client.apply(manifest, defaultNamespace: "default", dryRun: true)
        print("Dry run OK: \(r.kind.apiVersion) \(r.kind.plural) \(r.object.namespace ?? "-")/\(r.object.name) created=\(r.created)")
    } catch {
        print("Dry run error: \(error.localizedDescription)")
    }
}
do {
    _ = try await client.resolveKind(apiVersion: "example.com/v1", kind: "Nope")
} catch {
    print("Expected error: \(error.localizedDescription)")
}
