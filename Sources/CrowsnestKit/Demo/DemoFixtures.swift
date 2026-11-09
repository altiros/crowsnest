import Foundation

/// Contents of the demo cluster: a small web shop, monitoring, batch jobs and the usual system workloads –
/// with a crash-looping worker and an unschedulable GPU job, so there is something to troubleshoot.
enum DemoFixtures {
    /// Apps whose pods are in CrashLoopBackOff.
    static let crashingApps: Set<String> = ["payment-worker"]

    // MARK: Builders

    static func labels(_ map: [String: String]) -> JSONValue { .object(map.mapValues { .string($0) }) }

    static func meta(_ name: String, _ namespace: String?, labels: [String: String] = [:], annotations: [String: String] = [:],
                     age: TimeInterval, now: Date) -> JSONValue {
        var m: JSONValue = ["name": .string(name), "creationTimestamp": .string(now.addingTimeInterval(-age).kubeString)]
        if let namespace { m["namespace"] = .string(namespace) }
        if !labels.isEmpty { m["labels"] = Self.labels(labels) }
        if !annotations.isEmpty { m["annotations"] = Self.labels(annotations) }
        return m
    }

    static let day: TimeInterval = 86_400
    static let hour: TimeInterval = 3_600

    static func container(_ name: String, _ image: String, ports: [Int] = [], cpu: String = "100m", memory: String = "128Mi",
                          cpuLimit: String? = nil, memoryLimit: String? = "256Mi", env: [String: String] = [:],
                          args: [String]? = nil, probe: Int? = nil, extraLimits: [String: String] = [:]) -> JSONValue {
        var c: JSONValue = ["name": .string(name), "image": .string(image), "imagePullPolicy": "IfNotPresent"]
        if !ports.isEmpty {
            c["ports"] = .array(ports.map { ["containerPort": .int(Int64($0)), "protocol": "TCP"] })
        }
        var limits: [String: JSONValue] = extraLimits.mapValues { .string($0) }
        if let cpuLimit { limits["cpu"] = .string(cpuLimit) }
        if let memoryLimit { limits["memory"] = .string(memoryLimit) }
        c["resources"] = ["requests": ["cpu": .string(cpu), "memory": .string(memory)], "limits": .object(limits)]
        if !env.isEmpty {
            c["env"] = .array(env.sorted { $0.key < $1.key }.map { ["name": .string($0.key), "value": .string($0.value)] })
        }
        if let args { c["args"] = .array(args.map { .string($0) }) }
        if let probe {
            c["readinessProbe"] = ["httpGet": ["path": "/healthz", "port": .int(Int64(probe))], "periodSeconds": 10]
            c["livenessProbe"] = ["httpGet": ["path": "/healthz", "port": .int(Int64(probe))], "periodSeconds": 20]
        }
        c["securityContext"] = ["allowPrivilegeEscalation": false, "runAsNonRoot": true, "readOnlyRootFilesystem": true,
                                "capabilities": ["drop": ["ALL"]]]
        return c
    }

    static func template(_ labels: [String: String], _ containers: [JSONValue], serviceAccount: String? = nil,
                         tolerations: [JSONValue] = [], volumes: [JSONValue] = [], annotations: [String: String] = [:]) -> JSONValue {
        var spec: JSONValue = ["containers": .array(containers), "terminationGracePeriodSeconds": 30, "dnsPolicy": "ClusterFirst"]
        if let serviceAccount { spec["serviceAccountName"] = .string(serviceAccount) }
        if !tolerations.isEmpty { spec["tolerations"] = .array(tolerations) }
        if !volumes.isEmpty { spec["volumes"] = .array(volumes) }
        var metadata: JSONValue = ["labels": Self.labels(labels)]
        if !annotations.isEmpty { metadata["annotations"] = Self.labels(annotations) }
        return ["metadata": metadata, "spec": spec]
    }

    static func deployment(_ name: String, _ ns: String, replicas: Int, labels: [String: String], _ containers: [JSONValue],
                           age: TimeInterval, now: Date, serviceAccount: String? = nil, extraLabels: [String: String] = [:],
                           annotations: [String: String] = [:]) -> JSONValue {
        ["apiVersion": "apps/v1", "kind": "Deployment",
         "metadata": meta(name, ns, labels: labels.merging(extraLabels) { a, _ in a },
                          annotations: annotations.merging(["deployment.kubernetes.io/revision": "1"]) { a, _ in a }, age: age, now: now),
         "spec": ["replicas": .int(Int64(replicas)), "selector": ["matchLabels": Self.labels(labels)],
                  "strategy": ["type": "RollingUpdate", "rollingUpdate": ["maxSurge": "25%", "maxUnavailable": "25%"]],
                  "revisionHistoryLimit": 10,
                  "template": template(labels, containers, serviceAccount: serviceAccount)]]
    }

    static func statefulSet(_ name: String, _ ns: String, replicas: Int, labels: [String: String], _ containers: [JSONValue],
                            storage: String, age: TimeInterval, now: Date, extraLabels: [String: String] = [:],
                            annotations: [String: String] = [:]) -> JSONValue {
        ["apiVersion": "apps/v1", "kind": "StatefulSet",
         "metadata": meta(name, ns, labels: labels.merging(extraLabels) { a, _ in a }, annotations: annotations, age: age, now: now),
         "spec": ["replicas": .int(Int64(replicas)), "serviceName": .string(name), "selector": ["matchLabels": Self.labels(labels)],
                  "updateStrategy": ["type": "RollingUpdate"], "podManagementPolicy": "OrderedReady",
                  "template": template(labels, containers),
                  "volumeClaimTemplates": [["metadata": ["name": "data"],
                                            "spec": ["accessModes": ["ReadWriteOnce"], "storageClassName": "local-path",
                                                     "resources": ["requests": ["storage": .string(storage)]]]]]]]
    }

    static func daemonSet(_ name: String, _ ns: String, labels: [String: String], _ containers: [JSONValue],
                          age: TimeInterval, now: Date, allNodes: Bool = true, extraLabels: [String: String] = [:]) -> JSONValue {
        let tolerations: [JSONValue] = allNodes ? [["operator": "Exists"]] : []
        return ["apiVersion": "apps/v1", "kind": "DaemonSet",
                "metadata": meta(name, ns, labels: labels.merging(extraLabels) { a, _ in a }, age: age, now: now),
                "spec": ["selector": ["matchLabels": Self.labels(labels)], "updateStrategy": ["type": "RollingUpdate"],
                         "template": template(labels, containers, tolerations: tolerations)]]
    }

    static func service(_ name: String, _ ns: String, selector: [String: String], ports: [(String, Int, Int)], clusterIP: String,
                        type: String = "ClusterIP", age: TimeInterval, now: Date, labels: [String: String] = [:],
                        loadBalancerIP: String? = nil) -> JSONValue {
        var s: JSONValue = [
            "apiVersion": "v1", "kind": "Service",
            "metadata": meta(name, ns, labels: labels, age: age, now: now),
            "spec": ["type": .string(type), "clusterIP": .string(clusterIP), "clusterIPs": [.string(clusterIP)],
                     "ipFamilies": ["IPv4"], "ipFamilyPolicy": "SingleStack", "sessionAffinity": "None",
                     "internalTrafficPolicy": "Cluster",
                     "ports": .array(ports.map { p in
                         var port: JSONValue = ["name": .string(p.0), "port": .int(Int64(p.1)), "targetPort": .int(Int64(p.2)), "protocol": "TCP"]
                         if type == "LoadBalancer" { port["nodePort"] = .int(Int64(30000 + p.1 % 2768)) }
                         return port
                     })],
            "status": ["loadBalancer": [:]],
        ]
        if !selector.isEmpty { s.set(Self.labels(selector), at: ["spec", "selector"]) }
        if let loadBalancerIP { s.set([["ip": .string(loadBalancerIP), "ipMode": "VIP"]], at: ["status", "loadBalancer", "ingress"]) }
        return s
    }

    static func configMap(_ name: String, _ ns: String, _ data: [String: String], age: TimeInterval, now: Date,
                          labels: [String: String] = [:]) -> JSONValue {
        ["apiVersion": "v1", "kind": "ConfigMap", "metadata": meta(name, ns, labels: labels, age: age, now: now),
         "data": Self.labels(data)]
    }

    static func secret(_ name: String, _ ns: String, type: String = "Opaque", _ data: [String: String], age: TimeInterval, now: Date,
                       labels: [String: String] = [:]) -> JSONValue {
        ["apiVersion": "v1", "kind": "Secret", "type": .string(type), "metadata": meta(name, ns, labels: labels, age: age, now: now),
         "data": .object(data.mapValues { .string(Data($0.utf8).base64EncodedString()) })]
    }

    static func node(_ name: String, ip: String, controlPlane: Bool, age: TimeInterval, now: Date) -> JSONValue {
        var labels = ["kubernetes.io/hostname": name, "kubernetes.io/os": "linux", "kubernetes.io/arch": "arm64",
                      "beta.kubernetes.io/os": "linux", "beta.kubernetes.io/arch": "arm64",
                      "node.kubernetes.io/instance-type": "demo.large", "topology.kubernetes.io/zone": controlPlane ? "zone-a" : (name.hasSuffix("1") ? "zone-a" : "zone-b"),
                      "topology.kubernetes.io/region": "demo-1"]
        if controlPlane { labels["node-role.kubernetes.io/control-plane"] = "" } else { labels["node-role.kubernetes.io/worker"] = "" }
        let since: JSONValue = .string(now.addingTimeInterval(-age).kubeString)
        let heartbeat: JSONValue = .string(now.addingTimeInterval(-12).kubeString)
        func condition(_ type: String, _ status: String, _ reason: String, _ message: String) -> JSONValue {
            ["type": .string(type), "status": .string(status), "reason": .string(reason), "message": .string(message),
             "lastHeartbeatTime": heartbeat, "lastTransitionTime": since]
        }
        var n: JSONValue = [
            "apiVersion": "v1", "kind": "Node",
            "metadata": meta(name, nil, labels: labels, annotations: ["node.alpha.kubernetes.io/ttl": "0",
                                                                    "volumes.kubernetes.io/controller-managed-attach-detach": "true"],
                             age: age, now: now),
            "spec": ["podCIDR": .string("10.42.\(name.last?.wholeNumberValue ?? 0).0/24"), "providerID": .string("demo://\(name)")],
            "status": [
                "addresses": [["type": "InternalIP", "address": .string(ip)], ["type": "Hostname", "address": .string(name)]],
                "capacity": ["cpu": controlPlane ? "2" : "4", "memory": controlPlane ? "4013576Ki" : "16365628Ki",
                             "pods": "110", "ephemeral-storage": "102626232Ki"],
                "allocatable": ["cpu": controlPlane ? "2" : "4", "memory": controlPlane ? "3911176Ki" : "16263228Ki",
                                "pods": "110", "ephemeral-storage": "99833802265"],
                "conditions": [
                    condition("MemoryPressure", "False", "KubeletHasSufficientMemory", "kubelet has sufficient memory available"),
                    condition("DiskPressure", "False", "KubeletHasNoDiskPressure", "kubelet has no disk pressure"),
                    condition("PIDPressure", "False", "KubeletHasSufficientPID", "kubelet has sufficient PID available"),
                    condition("Ready", "True", "KubeletReady", "kubelet is posting ready status"),
                ],
                "nodeInfo": ["architecture": "arm64", "containerRuntimeVersion": "containerd://2.1.4", "kernelVersion": "6.12.48-0-lts",
                             "kubeProxyVersion": "", "kubeletVersion": "v1.34.2", "operatingSystem": "linux",
                             "osImage": "Ubuntu 24.04.3 LTS", "machineID": .string(String(repeating: "\(name.count)", count: 32)),
                             "systemUUID": .string("demo-\(name)"), "bootID": .string("boot-\(name)")],
                "images": [],
            ],
        ]
        if controlPlane {
            n.set([["key": "node-role.kubernetes.io/control-plane", "effect": "NoSchedule"]], at: ["spec", "taints"])
        }
        return n
    }

    static func namespace(_ name: String, age: TimeInterval, now: Date, labels: [String: String] = [:]) -> JSONValue {
        ["apiVersion": "v1", "kind": "Namespace",
         "metadata": meta(name, nil, labels: labels.merging(["kubernetes.io/metadata.name": name]) { a, _ in a }, age: age, now: now),
         "spec": ["finalizers": ["kubernetes"]], "status": ["phase": "Active"]]
    }

    // MARK: Objects

    static func objects(now: Date) -> [JSONValue] {
        var o: [JSONValue] = []
        let clusterAge = 142 * day
        let helmLabels = { (release: String, chart: String, version: String, app: String) -> [String: String] in
            ["app.kubernetes.io/name": app, "app.kubernetes.io/instance": release, "app.kubernetes.io/managed-by": "Helm",
             "app.kubernetes.io/version": version, "helm.sh/chart": chart]
        }
        let helmAnnotations = { (release: String, ns: String) -> [String: String] in
            ["meta.helm.sh/release-name": release, "meta.helm.sh/release-namespace": ns]
        }

        // Nodes & namespaces
        o.append(node("demo-control-plane", ip: "10.0.0.10", controlPlane: true, age: clusterAge, now: now))
        o.append(node("demo-worker-1", ip: "10.0.0.11", controlPlane: false, age: clusterAge, now: now))
        o.append(node("demo-worker-2", ip: "10.0.0.12", controlPlane: false, age: 37 * day, now: now))
        let namespaces: [(String, TimeInterval, [String: String])] = [
            ("default", clusterAge, [:]), ("kube-system", clusterAge, [:]), ("kube-public", clusterAge, [:]),
            ("kube-node-lease", clusterAge, [:]), ("ingress-nginx", clusterAge - day, [:]),
            ("shop", 96 * day, ["team": "storefront", "pod-security.kubernetes.io/enforce": "restricted"]),
            ("monitoring", 120 * day, ["team": "platform"]), ("batch", 61 * day, ["team": "data"]),
        ]
        for (name, age, labels) in namespaces {
            o.append(namespace(name, age: age, now: now, labels: labels))
            o.append(["apiVersion": "v1", "kind": "ServiceAccount", "metadata": meta("default", name, age: age, now: now)])
            o.append(configMap("kube-root-ca.crt", name, ["ca.crt": demoCertificate], age: age, now: now))
        }

        // Cluster-wide
        o.append(["apiVersion": "storage.k8s.io/v1", "kind": "StorageClass",
                  "metadata": meta("local-path", nil, annotations: ["storageclass.kubernetes.io/is-default-class": "true"], age: clusterAge, now: now),
                  "provisioner": "rancher.io/local-path", "reclaimPolicy": "Delete", "volumeBindingMode": "WaitForFirstConsumer"])
        o.append(["apiVersion": "networking.k8s.io/v1", "kind": "IngressClass",
                  "metadata": meta("nginx", nil, labels: ["app.kubernetes.io/name": "ingress-nginx"],
                                   annotations: ["ingressclass.kubernetes.io/is-default-class": "true"], age: clusterAge, now: now),
                  "spec": ["controller": "k8s.io/ingress-nginx"]])
        o.append(["apiVersion": "scheduling.k8s.io/v1", "kind": "PriorityClass",
                  "metadata": meta("shop-critical", nil, age: 96 * day, now: now), "value": 100000, "globalDefault": false,
                  "description": "Customer-facing shop workloads"])
        for (name, rules) in [("cluster-admin", [["apiGroups": ["*"], "resources": ["*"], "verbs": ["*"]] as JSONValue]),
                              ("view", [["apiGroups": [""], "resources": ["pods", "services", "configmaps"], "verbs": ["get", "list", "watch"]]]),
                              ("shop-deployer", [["apiGroups": ["apps"], "resources": ["deployments", "statefulsets"],
                                                  "verbs": ["get", "list", "watch", "patch", "update"]]])] {
            o.append(["apiVersion": "rbac.authorization.k8s.io/v1", "kind": "ClusterRole",
                      "metadata": meta(name, nil, labels: name == "shop-deployer" ? [:] : ["kubernetes.io/bootstrapping": "rbac-defaults"],
                                       age: clusterAge, now: now), "rules": .array(rules)])
        }
        o.append(["apiVersion": "rbac.authorization.k8s.io/v1", "kind": "ClusterRoleBinding",
                  "metadata": meta("cluster-admin", nil, age: clusterAge, now: now),
                  "roleRef": ["apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": "cluster-admin"],
                  "subjects": [["apiGroup": "rbac.authorization.k8s.io", "kind": "Group", "name": "system:masters"]]])
        o.append(["apiVersion": "rbac.authorization.k8s.io/v1", "kind": "ClusterRoleBinding",
                  "metadata": meta("ci-deployer", nil, age: 80 * day, now: now),
                  "roleRef": ["apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": "shop-deployer"],
                  "subjects": [["kind": "ServiceAccount", "name": "ci", "namespace": "shop"]]])

        // default
        o.append(service("kubernetes", "default", selector: [:], ports: [("https", 443, 6443)], clusterIP: "10.43.0.1",
                         age: clusterAge, now: now, labels: ["component": "apiserver", "provider": "kubernetes"]))
        o.append(["apiVersion": "v1", "kind": "Endpoints", "metadata": meta("kubernetes", "default", age: clusterAge, now: now),
                  "subsets": [["addresses": [["ip": "10.0.0.10"]], "ports": [["name": "https", "port": 6443, "protocol": "TCP"]]]]])

        // kube-system
        let sys = "kube-system"
        o.append(deployment("coredns", sys, replicas: 2, labels: ["k8s-app": "kube-dns"],
                            [container("coredns", "registry.k8s.io/coredns/coredns:v1.12.3", ports: [53, 9153], cpu: "100m", memory: "70Mi",
                                       memoryLimit: "170Mi", args: ["-conf", "/etc/coredns/Corefile"], probe: 8080)],
                            age: clusterAge, now: now, serviceAccount: "coredns"))
        o.append(service("kube-dns", sys, selector: ["k8s-app": "kube-dns"], ports: [("dns", 53, 53), ("metrics", 9153, 9153)],
                         clusterIP: "10.43.0.10", age: clusterAge, now: now, labels: ["k8s-app": "kube-dns"]))
        o.append(configMap("coredns", sys, ["Corefile": """
            .:53 {
                errors
                health
                ready
                kubernetes cluster.local in-addr.arpa ip6.arpa {
                  pods insecure
                  fallthrough in-addr.arpa ip6.arpa
                }
                prometheus :9153
                forward . /etc/resolv.conf
                cache 30
                loop
                reload
                loadbalance
            }
            """], age: clusterAge, now: now))
        o.append(deployment("metrics-server", sys, replicas: 1, labels: ["k8s-app": "metrics-server"],
                            [container("metrics-server", "registry.k8s.io/metrics-server/metrics-server:v0.8.0", ports: [10250],
                                       cpu: "100m", memory: "200Mi", memoryLimit: nil,
                                       args: ["--cert-dir=/tmp", "--secure-port=10250", "--kubelet-preferred-address-types=InternalIP",
                                              "--metric-resolution=15s"])],
                            age: clusterAge, now: now, serviceAccount: "metrics-server"))
        o.append(service("metrics-server", sys, selector: ["k8s-app": "metrics-server"], ports: [("https", 443, 10250)],
                         clusterIP: "10.43.112.4", age: clusterAge, now: now))
        o.append(daemonSet("kube-proxy", sys, labels: ["k8s-app": "kube-proxy"],
                           [container("kube-proxy", "registry.k8s.io/kube-proxy:v1.34.2", cpu: "50m", memory: "40Mi", memoryLimit: nil)],
                           age: clusterAge, now: now))
        for sa in ["coredns", "metrics-server"] {
            o.append(["apiVersion": "v1", "kind": "ServiceAccount", "metadata": meta(sa, sys, age: clusterAge, now: now)])
        }
        for lease in ["kube-controller-manager", "kube-scheduler"] {
            o.append(["apiVersion": "coordination.k8s.io/v1", "kind": "Lease", "metadata": meta(lease, sys, age: clusterAge, now: now),
                      "spec": ["holderIdentity": .string("demo-control-plane_\(lease)"), "leaseDurationSeconds": 15,
                               "renewTime": .string(now.addingTimeInterval(-3).kubeString)]])
        }

        // ingress-nginx
        let ing = "ingress-nginx"
        let ingressLabels = ["app.kubernetes.io/name": "ingress-nginx", "app.kubernetes.io/component": "controller"]
        o.append(deployment("ingress-nginx-controller", ing, replicas: 2, labels: ingressLabels,
                            [container("controller", "registry.k8s.io/ingress-nginx/controller:v1.13.3", ports: [80, 443, 10254],
                                       cpu: "100m", memory: "90Mi", memoryLimit: "512Mi", probe: 10254)],
                            age: clusterAge - day, now: now, serviceAccount: "ingress-nginx"))
        o.append(service("ingress-nginx-controller", ing, selector: ingressLabels, ports: [("http", 80, 80), ("https", 443, 443)],
                         clusterIP: "10.43.20.15", type: "LoadBalancer", age: clusterAge - day, now: now, labels: ingressLabels,
                         loadBalancerIP: "203.0.113.10"))
        o.append(["apiVersion": "v1", "kind": "ServiceAccount", "metadata": meta("ingress-nginx", ing, age: clusterAge - day, now: now)])

        // shop
        let shop = "shop"
        let shopAge = 96 * day
        o.append(deployment("frontend", shop, replicas: 3, labels: ["app": "frontend"],
                            [container("frontend", "nginxinc/nginx-unprivileged:1.27-alpine", ports: [8080], cpu: "50m", memory: "64Mi",
                                       memoryLimit: "128Mi", probe: 8080)],
                            age: 6 * day, now: now, extraLabels: ["app.kubernetes.io/part-of": "shop", "tier": "web"]))
        o.append(deployment("catalog-api", shop, replicas: 2, labels: ["app": "catalog-api"],
                            [container("api", "ghcr.io/crowsnest-demo/catalog-api:3.8.2", ports: [8080], cpu: "200m", memory: "256Mi",
                                       memoryLimit: "512Mi", env: ["DATABASE_HOST": "postgres", "CACHE_URL": "redis://redis-master:6379",
                                                                   "LOG_LEVEL": "info"], probe: 8080)],
                            age: 2 * day, now: now, serviceAccount: "catalog-api", extraLabels: ["app.kubernetes.io/part-of": "shop", "tier": "api"]))
        o.append(deployment("cart-api", shop, replicas: 2, labels: ["app": "cart-api"],
                            [container("api", "ghcr.io/crowsnest-demo/cart-api:1.14.0", ports: [8080], cpu: "150m", memory: "192Mi",
                                       memoryLimit: "384Mi", env: ["CACHE_URL": "redis://redis-master:6379", "LOG_LEVEL": "info"], probe: 8080)],
                            age: 13 * day, now: now, extraLabels: ["app.kubernetes.io/part-of": "shop", "tier": "api"]))
        o.append(deployment("payment-worker", shop, replicas: 1, labels: ["app": "payment-worker"],
                            [container("worker", "ghcr.io/crowsnest-demo/payment-worker:0.9.4", cpu: "100m", memory: "128Mi",
                                       env: ["PAYMENT_GATEWAY_URL": "https://payments.example.com", "DATABASE_HOST": "postgres"])],
                            age: 3 * hour, now: now, extraLabels: ["app.kubernetes.io/part-of": "shop", "tier": "worker"]))
        o.append(statefulSet("postgres", shop, replicas: 1, labels: ["app": "postgres"],
                             [container("postgres", "postgres:16.4-alpine", ports: [5432], cpu: "250m", memory: "512Mi", memoryLimit: "1Gi",
                                        env: ["POSTGRES_DB": "shop", "PGDATA": "/var/lib/postgresql/data/pgdata"])],
                             storage: "20Gi", age: shopAge, now: now, extraLabels: ["app.kubernetes.io/part-of": "shop", "tier": "data"]))
        let redisLabels = ["app.kubernetes.io/name": "redis", "app.kubernetes.io/instance": "redis", "app.kubernetes.io/component": "master"]
        o.append(statefulSet("redis-master", shop, replicas: 1, labels: redisLabels,
                             [container("redis", "redis:7.4.2-alpine", ports: [6379], cpu: "100m", memory: "128Mi", memoryLimit: "256Mi")],
                             storage: "8Gi", age: 41 * day, now: now,
                             extraLabels: helmLabels("redis", "redis-20.6.1", "7.4.2", "redis").merging(["app.kubernetes.io/component": "master"]) { _, b in b },
                             annotations: helmAnnotations("redis", shop)))
        o.append(service("frontend", shop, selector: ["app": "frontend"], ports: [("http", 80, 8080)], clusterIP: "10.43.88.21",
                         age: shopAge, now: now, labels: ["app": "frontend"]))
        o.append(service("catalog-api", shop, selector: ["app": "catalog-api"], ports: [("http", 8080, 8080)], clusterIP: "10.43.88.40",
                         age: shopAge, now: now, labels: ["app": "catalog-api"]))
        o.append(service("cart-api", shop, selector: ["app": "cart-api"], ports: [("http", 8080, 8080)], clusterIP: "10.43.88.52",
                         age: shopAge, now: now, labels: ["app": "cart-api"]))
        o.append(service("postgres", shop, selector: ["app": "postgres"], ports: [("postgres", 5432, 5432)], clusterIP: "10.43.90.7",
                         age: shopAge, now: now, labels: ["app": "postgres"]))
        o.append(service("redis-master", shop, selector: redisLabels, ports: [("tcp-redis", 6379, 6379)], clusterIP: "10.43.90.33",
                         age: 41 * day, now: now, labels: helmLabels("redis", "redis-20.6.1", "7.4.2", "redis")))
        o.append(["apiVersion": "networking.k8s.io/v1", "kind": "Ingress",
                  "metadata": meta("shop", shop, annotations: ["cert-manager.io/cluster-issuer": "letsencrypt",
                                                               "nginx.ingress.kubernetes.io/proxy-body-size": "8m"], age: shopAge, now: now),
                  "spec": ["ingressClassName": "nginx",
                           "tls": [["hosts": ["shop.example.com"], "secretName": "shop-tls"]],
                           "rules": [["host": "shop.example.com", "http": ["paths": [
                               ["path": "/api/catalog", "pathType": "Prefix", "backend": ["service": ["name": "catalog-api", "port": ["number": 8080]]]],
                               ["path": "/api/cart", "pathType": "Prefix", "backend": ["service": ["name": "cart-api", "port": ["number": 8080]]]],
                               ["path": "/", "pathType": "Prefix", "backend": ["service": ["name": "frontend", "port": ["number": 80]]]],
                           ]]]]],
                  "status": ["loadBalancer": ["ingress": [["ip": "203.0.113.10"]]]]])
        o.append(configMap("frontend-config", shop, ["default.conf": """
            server {
                listen 8080;
                root /usr/share/nginx/html;
                location / { try_files $uri /index.html; }
                location /healthz { return 200 'ok'; }
            }
            """], age: 6 * day, now: now))
        o.append(configMap("catalog-config", shop, ["application.yaml": "cache:\n  ttl: 300\nfeatures:\n  recommendations: true\n  newCheckout: false\n",
                                                   "PAGE_SIZE": "24"], age: 2 * day, now: now))
        o.append(secret("postgres-credentials", shop, ["username": "shop", "password": "demo-password-not-real"], age: shopAge, now: now))
        o.append(secret("shop-tls", shop, type: "kubernetes.io/tls", ["tls.crt": demoCertificate, "tls.key": "-----BEGIN PRIVATE KEY-----\n(demo)\n-----END PRIVATE KEY-----\n"],
                        age: 12 * day, now: now, labels: ["controller.cert-manager.io/fao": "true"]))
        o.append(["apiVersion": "v1", "kind": "ServiceAccount", "metadata": meta("catalog-api", shop, age: shopAge, now: now)])
        o.append(["apiVersion": "v1", "kind": "ServiceAccount", "metadata": meta("ci", shop, age: 80 * day, now: now)])
        o.append(["apiVersion": "rbac.authorization.k8s.io/v1", "kind": "Role", "metadata": meta("config-reader", shop, age: shopAge, now: now),
                  "rules": [["apiGroups": [""], "resources": ["configmaps"], "verbs": ["get", "list", "watch"]]]])
        o.append(["apiVersion": "rbac.authorization.k8s.io/v1", "kind": "RoleBinding", "metadata": meta("catalog-config-reader", shop, age: shopAge, now: now),
                  "roleRef": ["apiGroup": "rbac.authorization.k8s.io", "kind": "Role", "name": "config-reader"],
                  "subjects": [["kind": "ServiceAccount", "name": "catalog-api", "namespace": "shop"]]])
        o.append(["apiVersion": "autoscaling/v2", "kind": "HorizontalPodAutoscaler", "metadata": meta("frontend", shop, age: shopAge, now: now),
                  "spec": ["scaleTargetRef": ["apiVersion": "apps/v1", "kind": "Deployment", "name": "frontend"], "minReplicas": 2, "maxReplicas": 6,
                           "metrics": [["type": "Resource", "resource": ["name": "cpu", "target": ["type": "Utilization", "averageUtilization": 70]]]]],
                  "status": ["currentReplicas": 3, "desiredReplicas": 3,
                             "currentMetrics": [["type": "Resource", "resource": ["name": "cpu", "current": ["averageUtilization": 46, "averageValue": "23m"]]]]]])
        o.append(["apiVersion": "policy/v1", "kind": "PodDisruptionBudget", "metadata": meta("frontend", shop, age: shopAge, now: now),
                  "spec": ["minAvailable": 2, "selector": ["matchLabels": ["app": "frontend"]]],
                  "status": ["currentHealthy": 3, "desiredHealthy": 2, "disruptionsAllowed": 1, "expectedPods": 3]])
        o.append(["apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy", "metadata": meta("postgres-from-apis", shop, age: shopAge, now: now),
                  "spec": ["podSelector": ["matchLabels": ["app": "postgres"]], "policyTypes": ["Ingress"],
                           "ingress": [["from": [["podSelector": ["matchLabels": ["tier": "api"]]]], "ports": [["port": 5432, "protocol": "TCP"]]]]]])
        o.append(["apiVersion": "v1", "kind": "ResourceQuota", "metadata": meta("shop-quota", shop, age: shopAge, now: now),
                  "spec": ["hard": ["requests.cpu": "4", "requests.memory": "8Gi", "pods": "40"]],
                  "status": ["hard": ["requests.cpu": "4", "requests.memory": "8Gi", "pods": "40"],
                             "used": ["requests.cpu": "1600m", "requests.memory": "2112Mi", "pods": "10"]]])
        o.append(["apiVersion": "v1", "kind": "LimitRange", "metadata": meta("defaults", shop, age: shopAge, now: now),
                  "spec": ["limits": [["type": "Container", "default": ["cpu": "500m", "memory": "256Mi"],
                                       "defaultRequest": ["cpu": "100m", "memory": "128Mi"]]]]])

        // monitoring
        let mon = "monitoring"
        let monAge = 120 * day
        o.append(statefulSet("prometheus", mon, replicas: 1, labels: ["app.kubernetes.io/name": "prometheus"],
                             [container("prometheus", "quay.io/prometheus/prometheus:v3.5.0", ports: [9090], cpu: "300m", memory: "1Gi",
                                        memoryLimit: "2Gi", args: ["--config.file=/etc/prometheus/prometheus.yml", "--storage.tsdb.retention.time=15d"],
                                        probe: 9090)],
                             storage: "50Gi", age: monAge, now: now))
        o.append(service("prometheus", mon, selector: ["app.kubernetes.io/name": "prometheus"], ports: [("web", 9090, 9090)],
                         clusterIP: "10.43.60.9", age: monAge, now: now))
        let grafanaLabels = ["app.kubernetes.io/name": "grafana", "app.kubernetes.io/instance": "grafana"]
        o.append(deployment("grafana", mon, replicas: 1, labels: grafanaLabels,
                            [container("grafana", "grafana/grafana:12.1.1", ports: [3000], cpu: "100m", memory: "192Mi", memoryLimit: "512Mi",
                                       env: ["GF_SERVER_ROOT_URL": "https://grafana.example.com"], probe: 3000)],
                            age: monAge, now: now, extraLabels: helmLabels("grafana", "grafana-9.4.5", "12.1.1", "grafana"),
                            annotations: helmAnnotations("grafana", mon)))
        o.append(service("grafana", mon, selector: grafanaLabels, ports: [("service", 80, 3000)], clusterIP: "10.43.60.31",
                         age: monAge, now: now, labels: helmLabels("grafana", "grafana-9.4.5", "12.1.1", "grafana")))
        o.append(daemonSet("node-exporter", mon, labels: ["app.kubernetes.io/name": "node-exporter"],
                           [container("node-exporter", "quay.io/prometheus/node-exporter:v1.9.1", ports: [9100], cpu: "20m", memory: "32Mi",
                                      memoryLimit: "64Mi", args: ["--path.rootfs=/host"])],
                           age: monAge, now: now))
        o.append(configMap("prometheus-config", mon, ["prometheus.yml": """
            global:
              scrape_interval: 30s
            scrape_configs:
              - job_name: kubernetes-pods
                kubernetes_sd_configs:
                  - role: pod
              - job_name: node-exporter
                static_configs:
                  - targets: ['node-exporter:9100']
            """], age: monAge, now: now))
        o.append(secret("grafana", mon, ["admin-user": "admin", "admin-password": "demo-password-not-real"], age: monAge, now: now,
                        labels: helmLabels("grafana", "grafana-9.4.5", "12.1.1", "grafana")))

        // batch
        let batch = "batch"
        let batchAge = 61 * day
        o.append(["apiVersion": "batch/v1", "kind": "CronJob", "metadata": meta("nightly-report", batch, age: batchAge, now: now),
                  "spec": ["schedule": "0 2 * * *", "timeZone": "Europe/Berlin", "concurrencyPolicy": "Forbid", "suspend": false,
                           "successfulJobsHistoryLimit": 3, "failedJobsHistoryLimit": 1,
                           "jobTemplate": ["spec": ["backoffLimit": 2, "template": template(["app": "nightly-report"],
                               [container("report", "ghcr.io/crowsnest-demo/report-job:2.1.0", cpu: "500m", memory: "512Mi", memoryLimit: "1Gi",
                                          args: ["--date=yesterday", "--upload=s3://reports"])])]]],
                  "status": ["lastScheduleTime": .string(lastRun(hour: 2, now: now).kubeString),
                             "lastSuccessfulTime": .string(lastRun(hour: 2, now: now).addingTimeInterval(212).kubeString)]])
        o.append(["apiVersion": "batch/v1", "kind": "CronJob", "metadata": meta("cleanup-sessions", batch, age: batchAge, now: now),
                  "spec": ["schedule": "*/30 * * * *", "concurrencyPolicy": "Replace", "suspend": false,
                           "successfulJobsHistoryLimit": 3, "failedJobsHistoryLimit": 1,
                           "jobTemplate": ["spec": ["template": template(["app": "cleanup-sessions"],
                               [container("cleanup", "ghcr.io/crowsnest-demo/cart-api:1.14.0", cpu: "50m", memory: "64Mi",
                                          args: ["cleanup", "--older-than=24h"])])]]],
                  "status": ["lastScheduleTime": .string(lastHalfHour(now).kubeString),
                             "lastSuccessfulTime": .string(lastHalfHour(now).addingTimeInterval(41).kubeString)]])
        o.append(deployment("ml-trainer", batch, replicas: 1, labels: ["app": "ml-trainer"],
                            [container("trainer", "ghcr.io/crowsnest-demo/recommender-train:0.4.0", cpu: "2", memory: "8Gi",
                                       memoryLimit: "8Gi", extraLimits: ["nvidia.com/gpu": "1"])],
                            age: 50 * 60, now: now, extraLabels: ["team": "data"]))

        // Helm release storage
        o.append(contentsOf: helmReleases(now: now))
        return o
    }

    /// Jobs of the CronJobs (they need the CronJob's uid, so they are added after the first store pass).
    static func jobs(for cronJob: JSONValue, now: Date) -> [JSONValue] {
        let name = cronJob.value(at: "metadata.name")?.string ?? ""
        let ns = cronJob.value(at: "metadata.namespace")?.string ?? "default"
        let runs: [Date] = name == "nightly-report"
            ? (0..<3).map { lastRun(hour: 2, now: now).addingTimeInterval(-Double($0) * day) }
            : (0..<3).map { lastHalfHour(now).addingTimeInterval(-Double($0) * 1800) }
        return runs.map { run in
            var job: JSONValue = ["apiVersion": "batch/v1", "kind": "Job",
                                  "metadata": ["name": .string("\(name)-\(Int(run.timeIntervalSince1970 / 60))"), "namespace": .string(ns),
                                               "creationTimestamp": .string(run.kubeString),
                                               "labels": ["app": .string(name)],
                                               "annotations": ["batch.kubernetes.io/cronjob-scheduled-timestamp": .string(run.kubeString)],
                                               "ownerReferences": [DemoState.ownerReference(cronJob)]],
                                  "spec": cronJob.value(at: "spec.jobTemplate.spec") ?? [:]]
            job.set(1, at: ["spec", "completions"])
            job.set(1, at: ["spec", "parallelism"])
            return job
        }
    }

    static func lastRun(hour: Int, now: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .gmt
        let today = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now) ?? now
        return today <= now ? today : today.addingTimeInterval(-day)
    }

    static func lastHalfHour(_ now: Date) -> Date {
        Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 1800).rounded(.down) * 1800)
    }

    // MARK: Helm

    static func helmReleases(now: Date) -> [JSONValue] {
        func release(_ name: String, _ ns: String, revision: Int, status: String, chart: String, version: String, appVersion: String,
                     description: String, deployed: Date, first: Date, values: JSONValue, chartValues: JSONValue, notes: String,
                     manifest: String) -> JSONValue {
            let payload: JSONValue = [
                "name": .string(name), "namespace": .string(ns), "version": .int(Int64(revision)),
                "info": ["status": .string(status), "description": .string(description), "notes": .string(notes),
                         "first_deployed": .string(first.kubeString), "last_deployed": .string(deployed.kubeString)],
                "chart": ["metadata": ["name": .string(chart), "version": .string(version), "appVersion": .string(appVersion),
                                       "description": .string(chartDescription[chart] ?? ""), "apiVersion": "v2", "type": "application"],
                          "values": chartValues],
                "config": values, "manifest": .string(manifest), "hooks": [],
            ]
            let inner = (try? payload.jsonData()) ?? Data()
            let release = Data(inner.base64EncodedString().utf8).base64EncodedString()
            return ["apiVersion": "v1", "kind": "Secret", "type": "helm.sh/release.v1",
                    "metadata": ["name": .string("sh.helm.release.v1.\(name).v\(revision)"), "namespace": .string(ns),
                                 "creationTimestamp": .string(deployed.kubeString),
                                 "labels": ["owner": "helm", "name": .string(name), "status": .string(status),
                                            "version": .string(String(revision)), "modifiedAt": .string(String(Int(deployed.timeIntervalSince1970)))]],
                    "data": ["release": .string(release)]]
        }
        let grafanaFirst = now.addingTimeInterval(-120 * day)
        let grafanaManifest = """
            ---
            # Source: grafana/templates/secret.yaml
            apiVersion: v1
            kind: Secret
            metadata:
              name: grafana
              namespace: monitoring
            type: Opaque
            ---
            # Source: grafana/templates/service.yaml
            apiVersion: v1
            kind: Service
            metadata:
              name: grafana
              namespace: monitoring
            spec:
              type: ClusterIP
              ports:
                - name: service
                  port: 80
                  targetPort: 3000
            ---
            # Source: grafana/templates/deployment.yaml
            apiVersion: apps/v1
            kind: Deployment
            metadata:
              name: grafana
              namespace: monitoring
            spec:
              replicas: 1
              template:
                spec:
                  containers:
                    - name: grafana
                      image: "grafana/grafana:%@"
            """
        let grafanaDefaults: JSONValue = ["replicas": 1, "image": ["repository": "grafana/grafana", "tag": ""],
                                          "service": ["type": "ClusterIP", "port": 80], "persistence": ["enabled": false],
                                          "adminUser": "admin", "ingress": ["enabled": false]]
        let notes = "1. Get your 'admin' user password by running:\n\n   kubectl get secret --namespace monitoring grafana -o jsonpath=\"{.data.admin-password}\" | base64 --decode ; echo\n"
        let redisDeployed = now.addingTimeInterval(-41 * day)
        return [
            release("grafana", "monitoring", revision: 1, status: "superseded", chart: "grafana", version: "9.2.10", appVersion: "12.0.2",
                    description: "Install complete", deployed: grafanaFirst, first: grafanaFirst,
                    values: ["adminUser": "admin"], chartValues: grafanaDefaults, notes: notes,
                    manifest: grafanaManifest.replacingOccurrences(of: "%@", with: "12.0.2")),
            release("grafana", "monitoring", revision: 2, status: "deployed", chart: "grafana", version: "9.4.5", appVersion: "12.1.1",
                    description: "Upgrade complete", deployed: now.addingTimeInterval(-9 * day), first: grafanaFirst,
                    values: ["adminUser": "admin", "env": ["GF_SERVER_ROOT_URL": "https://grafana.example.com"],
                             "resources": ["requests": ["cpu": "100m", "memory": "192Mi"], "limits": ["memory": "512Mi"]]],
                    chartValues: grafanaDefaults, notes: notes,
                    manifest: grafanaManifest.replacingOccurrences(of: "%@", with: "12.1.1")),
            release("redis", "shop", revision: 1, status: "deployed", chart: "redis", version: "20.6.1", appVersion: "7.4.2",
                    description: "Install complete", deployed: redisDeployed, first: redisDeployed,
                    values: ["architecture": "standalone", "auth": ["enabled": false], "master": ["persistence": ["size": "8Gi"]]],
                    chartValues: ["architecture": "replication", "auth": ["enabled": true], "master": ["persistence": ["enabled": true, "size": "8Gi"]],
                                  "replica": ["replicaCount": 3]],
                    notes: "Redis can be accessed on the following DNS name from within your cluster:\n\n    redis-master.shop.svc.cluster.local\n",
                    manifest: "---\n# Source: redis/templates/master/service.yaml\napiVersion: v1\nkind: Service\nmetadata:\n  name: redis-master\n  namespace: shop\n---\n# Source: redis/templates/master/application.yaml\napiVersion: apps/v1\nkind: StatefulSet\nmetadata:\n  name: redis-master\n  namespace: shop\n"),
        ]
    }

    static let chartDescription = [
        "grafana": "The leading tool for querying and visualizing time series and metrics.",
        "redis": "Redis is an open source, advanced key-value store.",
    ]

    // MARK: Events

    static func seedEvents(into state: inout DemoState, now: Date) {
        for cronJob in state.all(.init(group: "batch", plural: "cronjobs")) {
            for job in jobs(for: cronJob, now: now) { state.put(job, now: now) }
            if let latest = state.owned(by: cronJob, .jobs).last {
                state.event(for: cronJob, reason: "SuccessfulCreate", message: "Created job \(latest.value(at: "metadata.name")?.string ?? "")",
                            component: "cronjob-controller", now: created(latest) ?? now)
                state.event(for: cronJob, reason: "SawCompletedJob",
                            message: "Saw completed job: \(latest.value(at: "metadata.name")?.string ?? ""), condition: Complete",
                            component: "cronjob-controller", now: (created(latest) ?? now).addingTimeInterval(60))
            }
        }
        state.reconcile(now: now, initial: true)
        for pod in state.all(.pods) {
            let podState = state.podState(pod, now: now)
            let name = pod.value(at: "metadata.name")?.string ?? ""
            if podState.crashLooping {
                let container = DemoState.containerNames(pod).first ?? name
                let image = pod.value(at: "spec.containers")?[0]?["image"]?.string ?? ""
                state.event(for: pod, reason: "Pulled", message: "Container image \"\(image)\" already present on machine",
                            count: 31, first: now.addingTimeInterval(-3 * hour), now: now.addingTimeInterval(-95))
                state.event(for: pod, reason: "BackOff", message: "Back-off restarting failed container \(container) in pod \(name)_shop(\(pod.value(at: "metadata.uid")?.string ?? ""))",
                            type: "Warning", count: 702, first: now.addingTimeInterval(-3 * hour + 120), now: now.addingTimeInterval(-20))
            } else if podState.unschedulable {
                state.event(for: pod, reason: "FailedScheduling",
                            message: "0/3 nodes are available: 1 node(s) had untolerated taint {node-role.kubernetes.io/control-plane: }, 2 Insufficient nvidia.com/gpu. preemption: 0/3 nodes are available: 3 No preemption victims found for incoming pod.",
                            type: "Warning", component: "default-scheduler", count: 11, first: now.addingTimeInterval(-50 * 60), now: now.addingTimeInterval(-4 * 60))
            }
        }
        if let catalog = state.get(.deployments, "shop", "catalog-api") {
            state.event(for: catalog, reason: "ScalingReplicaSet", message: "Scaled up replica set catalog-api-\(DemoState.templateHash(catalog.value(at: "spec.template") ?? [:])) from 0 to 2",
                        component: "deployment-controller", now: now.addingTimeInterval(-2 * day))
        }
        if let hpa = state.get(.init(group: "autoscaling", plural: "horizontalpodautoscalers"), "shop", "frontend") {
            state.event(for: hpa, reason: "SuccessfulRescale", message: "New size: 3; reason: cpu resource utilization (percentage of request) above target",
                        component: "horizontal-pod-autoscaler", now: now.addingTimeInterval(-47 * 60))
        }
        if let worker2 = state.get(.nodes, nil, "demo-worker-2") {
            state.event(for: worker2, reason: "NodeReady", message: "Node demo-worker-2 status is now: NodeReady",
                        component: "node-controller", now: now.addingTimeInterval(-37 * day))
        }
        if let ingress = state.get(.init(group: "networking.k8s.io", plural: "ingresses"), "shop", "shop") {
            state.event(for: ingress, reason: "Sync", message: "Scheduled for sync", component: "nginx-ingress-controller",
                        count: 4, first: now.addingTimeInterval(-96 * day), now: now.addingTimeInterval(-6 * day))
        }
    }

    private static func created(_ o: JSONValue) -> Date? {
        o.value(at: "metadata.creationTimestamp")?.string.flatMap(KubeDate.parse)
    }

    static let demoCertificate = """
        -----BEGIN CERTIFICATE-----
        MIIBdzCCAR2gAwIBAgIBADAKBggqhkjOPQQDAjAjMSEwHwYDVQQDDBhrM3Mtc2Vy
        dmVyLWNhQGNyb3dzbmVzdC1kZW1vMB4XDTI2MDYyMDEwMDAwMFoXDTM2MDYxODEw
        MDAwMFowIzEhMB8GA1UEAwwYazNzLXNlcnZlci1jYUBjcm93c25lc3QtZGVtbzBZ
        (demo certificate – not a real key)
        -----END CERTIFICATE-----
        """
}

// MARK: - Logs

enum DemoLogs {
    static func interval(app: String) -> TimeInterval {
        switch app {
        case "frontend", "ingress-nginx": 2.5
        case "catalog-api", "cart-api": 4
        case "kube-dns", "coredns": 9
        case "postgres", "redis", "prometheus": 45
        default: 20
        }
    }

    private static func pick<T>(_ items: [T], _ seed: UInt64, _ i: Int, _ salt: UInt64 = 0) -> T {
        var rng = SplitMix64(seed: seed &+ UInt64(truncatingIfNeeded: i) &* 7919 &+ salt)
        return items[Int(rng.next() % UInt64(items.count))]
    }

    private static func number(_ range: ClosedRange<Int>, _ seed: UInt64, _ i: Int, _ salt: UInt64) -> Int {
        var rng = SplitMix64(seed: seed &+ UInt64(truncatingIfNeeded: i) &* 104_729 &+ salt)
        return range.lowerBound + Int(rng.next() % UInt64(range.count))
    }

    static func line(app: String, container: String, index i: Int, seed: UInt64, at date: Date) -> String {
        let ts = date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).dateTimeSeparator(.standard))
        switch app {
        case "frontend", "ingress-nginx":
            let path = pick(["/", "/products", "/products/\(number(1...240, seed, i, 1))", "/cart", "/checkout", "/assets/app.js",
                             "/assets/styles.css", "/api/catalog/items?page=\(number(1...6, seed, i, 2))", "/healthz"], seed, i)
            let status = path == "/checkout" && number(0...9, seed, i, 3) == 0 ? 502 : (path.hasPrefix("/products/") && number(0...19, seed, i, 4) == 0 ? 404 : 200)
            let agent = pick(["Mozilla/5.0 (Macintosh; Intel Mac OS X 15_6) AppleWebKit/605.1.15", "Mozilla/5.0 (iPhone; CPU iPhone OS 26_1 like Mac OS X)",
                              "kube-probe/1.34", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/141.0"], seed, i, 5)
            let clf = date.formatted(Date.VerbatimFormatStyle(format: "\(day: .twoDigits)/\(month: .abbreviated)/\(year: .defaultDigits):\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits) +0000",
                                                              locale: Locale(identifier: "en_US_POSIX"), timeZone: .gmt, calendar: Calendar(identifier: .gregorian)))
            return "10.42.\(number(0...2, seed, i, 6)).\(number(2...250, seed, i, 7)) - - [\(clf)] \"GET \(path) HTTP/1.1\" \(status) \(number(180...48_000, seed, i, 8)) \"-\" \"\(agent)\""
        case "catalog-api", "cart-api":
            let route = app == "cart-api"
                ? pick(["GET /api/cart", "POST /api/cart/items", "DELETE /api/cart/items/\(number(1...99, seed, i, 1))", "GET /healthz"], seed, i)
                : pick(["GET /api/catalog/items", "GET /api/catalog/items/\(number(1...240, seed, i, 1))", "GET /api/catalog/search?q=\(pick(["boots", "jacket", "lamp", "mug"], seed, i, 2))", "GET /healthz"], seed, i)
            let parts = route.split(separator: " ")
            if number(0...40, seed, i, 9) == 0 {
                return "{\"time\":\"\(ts)\",\"level\":\"warn\",\"msg\":\"slow query\",\"table\":\"items\",\"duration_ms\":\(number(800...2400, seed, i, 10))}"
            }
            return "{\"time\":\"\(ts)\",\"level\":\"info\",\"msg\":\"request completed\",\"method\":\"\(parts[0])\",\"path\":\"\(parts[1])\",\"status\":200,\"duration_ms\":\(number(2...90, seed, i, 11)),\"cache\":\"\(pick(["hit", "hit", "miss"], seed, i, 12))\"}"
        case "postgres":
            return pick(["\(ts) UTC [\(number(60...90, seed, i, 1))] LOG:  checkpoint starting: time",
                         "\(ts) UTC [\(number(60...90, seed, i, 1))] LOG:  checkpoint complete: wrote \(number(3...180, seed, i, 2)) buffers (\(number(0...2, seed, i, 3)).\(number(0...9, seed, i, 4))%); 0 WAL file(s) added, 0 removed, 0 recycled",
                         "\(ts) UTC [\(number(1000...9999, seed, i, 5))] LOG:  automatic vacuum of table \"shop.public.\(pick(["orders", "items", "sessions"], seed, i, 6))\": index scans: 1"], seed, i)
        case "redis":
            return "1:M \(date.formatted(.dateTime.day(.twoDigits).month(.abbreviated).year().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits).locale(Locale(identifier: "en_GB")))).\(number(100...999, seed, i, 1)) * \(number(1...200, seed, i, 2)) changes in 60 seconds. Saving..."
        case "kube-dns", "coredns":
            let name = pick(["catalog-api.shop.svc.cluster.local.", "postgres.shop.svc.cluster.local.", "redis-master.shop.svc.cluster.local.",
                             "prometheus.monitoring.svc.cluster.local.", "payments.example.com."], seed, i)
            return "[INFO] 10.42.\(number(0...2, seed, i, 1)).\(number(2...250, seed, i, 2)):\(number(30000...60000, seed, i, 3)) - \(number(1000...65000, seed, i, 4)) \"A IN \(name) udp \(number(40...80, seed, i, 5)) false 512\" NOERROR qr,aa,rd 106 0.000\(number(100...999, seed, i, 6))s"
        case "prometheus":
            return "time=\(ts) level=INFO source=head.go:\(number(1100...1400, seed, i, 1)) msg=\"Head GC completed\" component=tsdb caller=truncateMemory duration=\(number(2...40, seed, i, 2)).\(number(100...999, seed, i, 3))ms"
        case "grafana":
            return "logger=context userId=\(number(0...3, seed, i, 1)) orgId=1 uname=\(pick(["admin", "", "anna"], seed, i, 2)) t=\(ts) level=info msg=\"Request Completed\" method=GET path=/api/\(pick(["dashboards/uid/k8s-overview", "datasources/proxy/1/api/v1/query_range", "search"], seed, i, 3)) status=200 duration=\(number(3...120, seed, i, 4))ms"
        case "metrics-server":
            return "I\(date.formatted(Date.VerbatimFormatStyle(format: "\(month: .twoDigits)\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits)", timeZone: .gmt, calendar: Calendar(identifier: .gregorian)))).\(number(100_000...999_999, seed, i, 1))       1 server.go:\(number(130...190, seed, i, 2))] \"Scraped\" nodes=3 duration=\"\(number(10...90, seed, i, 3))ms\""
        case "nightly-report":
            return "\(ts) INFO  report: processed \(number(200...5000, seed, i, 1)) orders for \(pick(["DE", "AT", "CH", "NL", "FR"], seed, i, 2))"
        case "cleanup-sessions":
            return "\(ts) INFO  cleanup: removed \(number(0...400, seed, i, 1)) expired sessions"
        default:
            return "\(ts) INFO  \(container): \(pick(["heartbeat ok", "sync completed", "watching for changes", "cache refreshed"], seed, i))"
        }
    }

    static func startup(app: String, at date: Date) -> [String] {
        let ts = date.formatted(.iso8601)
        switch app {
        case "frontend":
            return ["/docker-entrypoint.sh: Configuration complete; ready for start up",
                    "\(ts) [notice] 1#1: nginx/1.27.5", "\(ts) [notice] 1#1: start worker processes"]
        case "postgres":
            return ["\(ts) UTC [1] LOG:  starting PostgreSQL 16.4 on aarch64-unknown-linux-musl",
                    "\(ts) UTC [1] LOG:  listening on IPv4 address \"0.0.0.0\", port 5432",
                    "\(ts) UTC [1] LOG:  database system is ready to accept connections"]
        case "catalog-api", "cart-api":
            return ["{\"time\":\"\(ts)\",\"level\":\"info\",\"msg\":\"starting \(app)\",\"version\":\"\(app == "cart-api" ? "1.14.0" : "3.8.2")\"}",
                    "{\"time\":\"\(ts)\",\"level\":\"info\",\"msg\":\"connected to redis\",\"addr\":\"redis-master:6379\"}",
                    "{\"time\":\"\(ts)\",\"level\":\"info\",\"msg\":\"listening\",\"addr\":\":8080\"}"]
        case "nightly-report", "cleanup-sessions":
            return ["\(ts) INFO  starting \(app)"]
        default:
            return []
        }
    }

    static func finish(app: String, at date: Date) -> [String] {
        ["\(date.formatted(.iso8601)) INFO  \(app) finished successfully"]
    }

    static func crash(app: String, at date: Date) -> [String] {
        let ts = date.formatted(.iso8601)
        return ["{\"time\":\"\(ts)\",\"level\":\"info\",\"msg\":\"starting payment-worker\",\"version\":\"0.9.4\"}",
                "{\"time\":\"\(ts)\",\"level\":\"info\",\"msg\":\"loading configuration\",\"gateway\":\"https://payments.example.com\"}",
                "{\"time\":\"\(ts)\",\"level\":\"error\",\"msg\":\"required setting missing\",\"key\":\"PAYMENT_API_KEY\"}",
                "panic: config: PAYMENT_API_KEY is not set",
                "",
                "goroutine 1 [running]:",
                "main.mustConfig(...)",
                "\t/src/cmd/worker/main.go:48 +0x1c4",
                "main.main()",
                "\t/src/cmd/worker/main.go:27 +0x58"]
    }
}
