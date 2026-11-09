import Foundation
import Testing
@testable import CrowsnestKit

@Suite struct DemoClusterTests {
    func client() throws -> KubeClient { try KubeClient(config: .demo) }

    @Test func connectsWithoutNetwork() async throws {
        let client = try client()
        #expect(ConnectionConfig.demo.isDemo)
        #expect(try await client.serverVersion().gitVersion == "v1.34.2")
        let namespaces = try await client.namespaceNames()
        #expect(namespaces.contains("shop") && namespaces.contains("kube-system"))
        #expect(try await client.customResourceKinds().isEmpty)
        await client.shutdown()
    }

    @Test func workloadsHavePods() async throws {
        let client = try client()
        let pods = try await client.list(.pods, namespace: "shop")
        #expect(pods.filter { $0.name.hasPrefix("frontend-") }.count == 3)
        #expect(pods.contains { $0.name == "postgres-0" })
        let frontend = try await client.get(.deployments, name: "frontend", namespace: "shop")
        #expect(frontend["status.readyReplicas"]?.int == 3)
        // Something to troubleshoot: a crash loop and an unschedulable pod.
        let worker = try #require(pods.first { $0.name.hasPrefix("payment-worker-") })
        #expect(worker["status.containerStatuses"]?[0]?["state"]?["waiting"]?["reason"]?.string == "CrashLoopBackOff")
        let trainer = try #require(try await client.list(.pods, namespace: "batch").first { $0.name.hasPrefix("ml-trainer-") })
        #expect(trainer["status.phase"]?.string == "Pending")
        let warnings = try await client.events(for: worker).filter { $0["type"]?.string == "Warning" }
        #expect(warnings.contains { $0["reason"]?.string == "BackOff" })
        // DaemonSets: kube-proxy on every node, PVCs for StatefulSets, endpoints for services.
        #expect(try await client.list(.pods, namespace: "kube-system", labelSelector: "k8s-app=kube-proxy").count == 3)
        #expect(try await client.list(.persistentVolumeClaims, namespace: "shop").contains { $0.name == "data-postgres-0" })
        let endpoints = try await client.get(.endpoints, name: "frontend", namespace: "shop")
        #expect(endpoints["subsets"]?[0]?["addresses"]?.array?.count == 3)
        await client.shutdown()
    }

    @Test func scaleRestartAndDelete() async throws {
        let client = try client()
        try await client.scale(.deployments, name: "cart-api", namespace: "shop", replicas: 4)
        #expect(try await client.list(.pods, namespace: "shop", labelSelector: "app=cart-api").count == 4)
        let before = Set(try await client.list(.pods, namespace: "shop", labelSelector: "app=cart-api").map(\.name))
        try await client.restart(.deployments, name: "cart-api", namespace: "shop")
        let after = try await client.list(.pods, namespace: "shop", labelSelector: "app=cart-api")
        #expect(after.count == 4 && before.isDisjoint(with: after.map(\.name)))
        // A deleted pod is replaced by its ReplicaSet.
        let victim = after[0].name
        try await client.delete(.pods, name: victim, namespace: "shop")
        let replaced = try await client.list(.pods, namespace: "shop", labelSelector: "app=cart-api")
        #expect(replaced.count == 4 && !replaced.contains { $0.name == victim })
        // Deleting the deployment removes ReplicaSets and pods.
        try await client.delete(.deployments, name: "cart-api", namespace: "shop")
        #expect(try await client.list(.pods, namespace: "shop", labelSelector: "app=cart-api").isEmpty)
        await client.shutdown()
    }

    @Test func applyCordonAndCronJob() async throws {
        let client = try client()
        let manifest: JSONValue = ["apiVersion": "v1", "kind": "ConfigMap", "metadata": ["name": "hello", "namespace": "default"],
                                   "data": ["greeting": "hi"]]
        #expect(try await client.apply(manifest, defaultNamespace: nil, dryRun: true).created)
        #expect((try? await client.get(.configMaps, name: "hello", namespace: "default")) == nil)  // dry run stores nothing
        #expect(try await client.apply(manifest, defaultNamespace: nil).created)
        #expect(try await client.get(.configMaps, name: "hello", namespace: "default")["data.greeting"]?.string == "hi")
        try await client.setUnschedulable(node: "demo-worker-1", true)
        #expect(try await client.get(.nodes, name: "demo-worker-1", namespace: nil)["spec.unschedulable"]?.bool == true)
        let cronJob = try await client.get(.cronJobs, name: "nightly-report", namespace: "batch")
        let job = try await client.trigger(cronJob: cronJob)
        #expect(try await client.list(.pods, namespace: "batch", labelSelector: "app=nightly-report").contains {
            ($0["metadata.ownerReferences"]?[0]?["name"]?.string) == job.name
        })
        await client.shutdown()
    }

    @Test func logsMetricsAndHelm() async throws {
        let client = try client()
        let pod = try #require(try await client.list(.pods, namespace: "shop", labelSelector: "app=frontend").first)
        let logs = try await client.logs(pod: pod.name, namespace: "shop", options: .init(tailLines: 50))
        #expect(logs.split(separator: "\n").count == 50)
        #expect(logs.contains("HTTP/1.1"))
        let usage = try #require(try await client.podMetrics(namespace: "shop"))
        #expect(usage["shop/\(pod.name)"]?.total.cpu ?? 0 > 0)
        #expect(try await client.nodeMetrics()?.count == 3)
        let releases = try await client.helmReleases(namespace: nil)
        #expect(Set(releases.map(\.name)) == ["grafana", "redis"])
        #expect(releases.first { $0.name == "grafana" }?.revision == 2)
        await client.shutdown()
    }

    @Test func shellIsNotAvailable() async throws {
        let client = try client()
        await #expect(throws: KubeError.self) {
            _ = try await client.openChannel(path: "/api/v1/namespaces/shop/pods/x/exec", query: [], protocols: [])
        }
        await client.shutdown()
    }

    @Test func demoContext() throws {
        let config = KubeConfig().addingDemoContext()
        #expect(config.contextNames == [DemoCluster.contextName])
        #expect(try config.connection(forContext: DemoCluster.contextName).isDemo)
        #expect(config.addingDemoContext().contextNames.count == 1)
    }
}
