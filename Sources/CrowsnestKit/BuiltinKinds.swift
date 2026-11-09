import Foundation

// Column helpers
private func text(_ path: String, _ fallback: String = "") -> @Sendable (KubeObject) -> CellValue {
    { .text($0[path]?.string ?? fallback) }
}
private func number(_ path: String) -> @Sendable (KubeObject) -> CellValue {
    { .number($0[path]?.int ?? 0) }
}
private func count(_ path: String) -> @Sendable (KubeObject) -> CellValue {
    { .number($0[path]?.object?.count ?? $0[path]?.array?.count ?? 0) }
}
private func replicasColumn(ready readyPath: String, desired desiredPath: String) -> ResourceColumn {
    ResourceColumn("Ready", width: .narrow) { o in
        let ready = o[readyPath]?.int ?? 0, desired = o[desiredPath]?.int ?? 0
        return .status("\(ready)/\(desired)", WorkloadStatus.tone(ready: ready, desired: desired))
    }
}
private func joined(_ values: [String]) -> String { values.isEmpty ? "–" : values.joined(separator: ", ") }

extension ResourceKind {
    // MARK: Cluster

    public static let nodes = ResourceKind(
        kind: "Node", plural: "nodes", namespaced: false, title: "Nodes", category: .cluster, symbol: "server.rack",
        columns: [
            ResourceColumn("Status") { .status(NodeStatus.status(of: $0).text, NodeStatus.status(of: $0).tone) },
            ResourceColumn("Roles") { .text(NodeStatus.roles(of: $0)) },
            ResourceColumn("Version", width: .narrow, value: text("status.nodeInfo.kubeletVersion")),
            ResourceColumn("Internal IP") { .text(NodeStatus.address(of: $0, type: "InternalIP") ?? "–") },
            ResourceColumn("CPU", width: .narrow, value: text("status.capacity.cpu")),
            ResourceColumn("Memory", width: .narrow) { o in
                guard let bytes = o["status.capacity.memory"]?.string.flatMap(Quantity.parse) else { return .text("–") }
                return .meter(value: bytes, fraction: nil, text: Quantity.formatBytes(bytes))  // sorts by bytes
            },
        ]
    )

    public static let namespaces = ResourceKind(
        kind: "Namespace", plural: "namespaces", namespaced: false, title: "Namespaces", category: .cluster, symbol: "square.stack.3d.up",
        columns: [
            ResourceColumn("Status") { o in
                let phase = o["status.phase"]?.string ?? "?"
                return .status(phase, phase == "Active" ? .ok : .progress)
            },
            ResourceColumn("Labels", width: .wide) { .text($0.labels.map { "\($0)=\($1)" }.sorted().joined(separator: ", ")) },
        ]
    )

    public static let events = ResourceKind(
        kind: "Event", plural: "events", title: "Events", category: .cluster, symbol: "bell",
        columns: [
            ResourceColumn("Type", width: .narrow) { o in
                let t = o["type"]?.string ?? ""
                return .status(t, t == "Warning" ? .warning : .neutral)
            },
            ResourceColumn("Reason", value: text("reason")),
            ResourceColumn("Object") { o in
                .text("\(o["involvedObject.kind"]?.string ?? "")/\(o["involvedObject.name"]?.string ?? "")")
            },
            ResourceColumn("Message", width: .wide, value: text("message")),
            ResourceColumn("Count", width: .narrow) { .number($0["count"]?.int ?? $0["series.count"]?.int ?? 1) },
            ResourceColumn("Last Seen", width: .narrow) { o in
                .age(EventInfo.lastSeen(o))
            },
        ]
    )

    // MARK: Workloads

    public static let pods = ResourceKind(
        kind: "Pod", plural: "pods", title: "Pods", category: .workloads, symbol: "shippingbox",
        columns: [
            ResourceColumn("Ready", width: .narrow) { o in
                let (r, t) = PodStatus.readiness(of: o)
                return .status("\(r)/\(t)", r == t ? .ok : (o["status.phase"]?.string == "Succeeded" ? .neutral : .warning))
            },
            ResourceColumn("Status") { .status(PodStatus.status(of: $0).text, PodStatus.status(of: $0).tone) },
            ResourceColumn("Restarts", width: .narrow) { .number(PodStatus.restarts(of: $0)) },
            ResourceColumn("Node", value: text("spec.nodeName", "–")),
            ResourceColumn("IP", value: text("status.podIP", "–")),
        ],
        capabilities: [.logs, .shell]
    )

    public static let deployments = ResourceKind(
        kind: "Deployment", group: "apps", plural: "deployments", title: "Deployments", category: .workloads, symbol: "square.stack.3d.forward.dottedline",
        columns: [
            replicasColumn(ready: "status.readyReplicas", desired: "spec.replicas"),
            ResourceColumn("Up-to-date", width: .narrow, value: number("status.updatedReplicas")),
            ResourceColumn("Available", width: .narrow, value: number("status.availableReplicas")),
            ResourceColumn("Images", width: .wide) { .text(joined(WorkloadInfo.images(of: $0))) },
        ],
        capabilities: [.scale, .restart, .logs]
    )

    public static let statefulSets = ResourceKind(
        kind: "StatefulSet", group: "apps", plural: "statefulsets", title: "StatefulSets", category: .workloads, symbol: "cylinder.split.1x2",
        columns: [
            replicasColumn(ready: "status.readyReplicas", desired: "spec.replicas"),
            ResourceColumn("Service", value: text("spec.serviceName", "–")),
            ResourceColumn("Images", width: .wide) { .text(joined(WorkloadInfo.images(of: $0))) },
        ],
        capabilities: [.scale, .restart, .logs]
    )

    public static let daemonSets = ResourceKind(
        kind: "DaemonSet", group: "apps", plural: "daemonsets", title: "DaemonSets", category: .workloads, symbol: "circle.grid.3x3",
        columns: [
            ResourceColumn("Desired", width: .narrow, value: number("status.desiredNumberScheduled")),
            ResourceColumn("Current", width: .narrow, value: number("status.currentNumberScheduled")),
            replicasColumn(ready: "status.numberReady", desired: "status.desiredNumberScheduled"),
            ResourceColumn("Up-to-date", width: .narrow, value: number("status.updatedNumberScheduled")),
            ResourceColumn("Available", width: .narrow, value: number("status.numberAvailable")),
            ResourceColumn("Node Selector") { .text($0["spec.template.spec.nodeSelector"]?.stringMap.map { "\($0)=\($1)" }.sorted().joined(separator: ",") ?? "–") },
        ],
        capabilities: [.restart, .logs]
    )

    public static let replicaSets = ResourceKind(
        kind: "ReplicaSet", group: "apps", plural: "replicasets", title: "ReplicaSets", category: .workloads, symbol: "square.on.square",
        columns: [
            ResourceColumn("Desired", width: .narrow, value: number("spec.replicas")),
            ResourceColumn("Current", width: .narrow, value: number("status.replicas")),
            replicasColumn(ready: "status.readyReplicas", desired: "spec.replicas"),
        ],
        capabilities: [.scale]
    )

    public static let jobs = ResourceKind(
        kind: "Job", group: "batch", plural: "jobs", title: "Jobs", category: .workloads, symbol: "hammer",
        columns: [
            ResourceColumn("Completions", width: .narrow) { o in
                .text("\(o["status.succeeded"]?.int ?? 0)/\(o["spec.completions"]?.int ?? 1)")
            },
            ResourceColumn("Status") { o in
                let s = JobInfo.status(of: o)
                return .status(s.text, s.tone)
            },
            ResourceColumn("Duration", width: .narrow) { o in
                guard let start = o["status.startTime"]?.string.flatMap(KubeDate.parse) else { return .text("–") }
                let end = o["status.completionTime"]?.string.flatMap(KubeDate.parse) ?? .now
                return .meter(value: end.timeIntervalSince(start), fraction: nil, text: KubeDate.age(since: start, now: end))  // sorts by seconds
            },
        ],
        capabilities: [.logs]
    )

    public static let cronJobs = ResourceKind(
        kind: "CronJob", group: "batch", plural: "cronjobs", title: "CronJobs", category: .workloads, symbol: "clock.arrow.circlepath",
        columns: [
            ResourceColumn("Schedule", value: text("spec.schedule")),
            ResourceColumn("Suspend", width: .narrow) { o in
                let s = o["spec.suspend"]?.bool ?? false
                return .status(s ? "True" : "False", s ? .warning : .neutral)
            },
            ResourceColumn("Active", width: .narrow, value: count("status.active")),
            ResourceColumn("Last Schedule", width: .narrow) { .age($0["status.lastScheduleTime"]?.string.flatMap(KubeDate.parse)) },
        ]
    )

    // MARK: Config

    public static let configMaps = ResourceKind(
        kind: "ConfigMap", plural: "configmaps", title: "ConfigMaps", category: .config, symbol: "doc.text",
        columns: [
            ResourceColumn("Keys", width: .wide) { o in
                .text(((o["data"]?.object?.keys).map(Array.init) ?? []).sorted().joined(separator: ", "))
            },
        ]
    )

    public static let secrets = ResourceKind(
        kind: "Secret", plural: "secrets", title: "Secrets", category: .config, symbol: "key",
        columns: [
            ResourceColumn("Type", width: .wide, value: text("type")),
            ResourceColumn("Keys", width: .narrow, value: count("data")),
        ]
    )

    public static let resourceQuotas = ResourceKind(
        kind: "ResourceQuota", plural: "resourcequotas", title: "Resource Quotas", category: .config, symbol: "gauge.with.dots.needle.33percent"
    )

    public static let limitRanges = ResourceKind(
        kind: "LimitRange", plural: "limitranges", title: "Limit Ranges", category: .config, symbol: "ruler"
    )

    public static let horizontalPodAutoscalers = ResourceKind(
        kind: "HorizontalPodAutoscaler", group: "autoscaling", version: "v2", plural: "horizontalpodautoscalers", title: "HPA",
        category: .config, symbol: "arrow.up.and.down.square",
        columns: [
            ResourceColumn("Reference") { .text("\($0["spec.scaleTargetRef.kind"]?.string ?? "")/\($0["spec.scaleTargetRef.name"]?.string ?? "")") },
            ResourceColumn("Min", width: .narrow) { .number($0["spec.minReplicas"]?.int ?? 1) },
            ResourceColumn("Max", width: .narrow, value: number("spec.maxReplicas")),
            ResourceColumn("Replicas", width: .narrow, value: number("status.currentReplicas")),
        ]
    )

    public static let podDisruptionBudgets = ResourceKind(
        kind: "PodDisruptionBudget", group: "policy", plural: "poddisruptionbudgets", title: "Pod Disruption Budgets",
        category: .config, symbol: "shield.lefthalf.filled",
        columns: [
            ResourceColumn("Min Available", width: .narrow, value: text("spec.minAvailable", "–")),
            ResourceColumn("Max Unavailable", width: .narrow, value: text("spec.maxUnavailable", "–")),
            ResourceColumn("Allowed Disruptions", width: .narrow, value: number("status.disruptionsAllowed")),
        ]
    )

    public static let priorityClasses = ResourceKind(
        kind: "PriorityClass", group: "scheduling.k8s.io", plural: "priorityclasses", namespaced: false, title: "Priority Classes",
        category: .config, symbol: "flag",
        columns: [
            ResourceColumn("Value", width: .narrow, value: number("value")),
            ResourceColumn("Global Default", width: .narrow) { .text(($0["globalDefault"]?.bool ?? false) ? "true" : "false") },
        ]
    )

    public static let leases = ResourceKind(
        kind: "Lease", group: "coordination.k8s.io", plural: "leases", title: "Leases", category: .config, symbol: "lock.rotation",
        columns: [ResourceColumn("Holder", width: .wide, value: text("spec.holderIdentity", "–"))]
    )

    public static let mutatingWebhooks = ResourceKind(
        kind: "MutatingWebhookConfiguration", group: "admissionregistration.k8s.io", plural: "mutatingwebhookconfigurations",
        namespaced: false, title: "Mutating Webhooks", category: .config, symbol: "arrow.triangle.branch",
        columns: [ResourceColumn("Webhooks", width: .narrow, value: count("webhooks"))]
    )

    public static let validatingWebhooks = ResourceKind(
        kind: "ValidatingWebhookConfiguration", group: "admissionregistration.k8s.io", plural: "validatingwebhookconfigurations",
        namespaced: false, title: "Validating Webhooks", category: .config, symbol: "checkmark.shield",
        columns: [ResourceColumn("Webhooks", width: .narrow, value: count("webhooks"))]
    )

    // MARK: Network

    public static let services = ResourceKind(
        kind: "Service", plural: "services", title: "Services", category: .network, symbol: "point.3.connected.trianglepath.dotted",
        columns: [
            ResourceColumn("Type", value: text("spec.type")),
            ResourceColumn("Cluster IP", value: text("spec.clusterIP", "–")),
            ResourceColumn("External IP") { .text(joined(ServiceInfo.externalAddresses(of: $0))) },
            ResourceColumn("Ports", width: .wide) { .text(ServiceInfo.ports(of: $0)) },
        ]
    )

    public static let endpoints = ResourceKind(
        kind: "Endpoints", plural: "endpoints", title: "Endpoints", category: .network, symbol: "point.topleft.down.to.point.bottomright.curvepath",
        columns: [
            ResourceColumn("Endpoints", width: .wide) { o in
                var result: [String] = []
                for subset in o["subsets"]?.array ?? [] {
                    let ports = (subset["ports"]?.array ?? []).compactMap { $0["port"]?.int }
                    for addr in subset["addresses"]?.array ?? [] {
                        let ip = addr["ip"]?.string ?? "?"
                        result += ports.isEmpty ? [ip] : ports.map { "\(ip):\($0)" }
                    }
                }
                return .text(result.isEmpty ? "<none>" : result.prefix(5).joined(separator: ", ") + (result.count > 5 ? " +\(result.count - 5)" : ""))
            },
        ]
    )

    public static let ingresses = ResourceKind(
        kind: "Ingress", group: "networking.k8s.io", plural: "ingresses", title: "Ingresses", category: .network, symbol: "globe",
        columns: [
            ResourceColumn("Class", value: text("spec.ingressClassName", "–")),
            ResourceColumn("Hosts", width: .wide) { o in
                .text(joined((o["spec.rules"]?.array ?? []).compactMap { $0["host"]?.string }))
            },
            ResourceColumn("Address") { o in
                .text(joined((o["status.loadBalancer.ingress"]?.array ?? []).compactMap { $0["ip"]?.string ?? $0["hostname"]?.string }))
            },
        ]
    )

    public static let ingressClasses = ResourceKind(
        kind: "IngressClass", group: "networking.k8s.io", plural: "ingressclasses", namespaced: false, title: "Ingress Classes",
        category: .network, symbol: "signpost.right",
        columns: [ResourceColumn("Controller", width: .wide, value: text("spec.controller"))]
    )

    public static let networkPolicies = ResourceKind(
        kind: "NetworkPolicy", group: "networking.k8s.io", plural: "networkpolicies", title: "Network Policies",
        category: .network, symbol: "network.badge.shield.half.filled",
        columns: [
            ResourceColumn("Pod Selector", width: .wide) { o in
                let sel = o["spec.podSelector.matchLabels"]?.stringMap ?? [:]
                return .text(sel.isEmpty ? "<all pods>" : sel.map { "\($0)=\($1)" }.sorted().joined(separator: ","))
            },
            ResourceColumn("Policy Types") { .text(joined(($0["spec.policyTypes"]?.array ?? []).compactMap(\.string))) },
        ]
    )

    // MARK: Storage

    public static let persistentVolumeClaims = ResourceKind(
        kind: "PersistentVolumeClaim", plural: "persistentvolumeclaims", title: "Persistent Volume Claims",
        category: .storage, symbol: "externaldrive",
        columns: [
            ResourceColumn("Status") { o in
                let p = o["status.phase"]?.string ?? "?"
                return .status(p, p == "Bound" ? .ok : (p == "Pending" ? .progress : .error))
            },
            ResourceColumn("Volume", width: .wide, value: text("spec.volumeName", "–")),
            ResourceColumn("Capacity", width: .narrow, value: text("status.capacity.storage", "–")),
            ResourceColumn("Access Modes") { .text(joined(($0["spec.accessModes"]?.array ?? []).compactMap(\.string))) },
            ResourceColumn("Storage Class", value: text("spec.storageClassName", "–")),
        ]
    )

    public static let persistentVolumes = ResourceKind(
        kind: "PersistentVolume", plural: "persistentvolumes", namespaced: false, title: "Persistent Volumes",
        category: .storage, symbol: "externaldrive.connected.to.line.below",
        columns: [
            ResourceColumn("Capacity", width: .narrow, value: text("spec.capacity.storage", "–")),
            ResourceColumn("Access Modes") { .text(joined(($0["spec.accessModes"]?.array ?? []).compactMap(\.string))) },
            ResourceColumn("Reclaim Policy", value: text("spec.persistentVolumeReclaimPolicy")),
            ResourceColumn("Status") { o in
                let p = o["status.phase"]?.string ?? "?"
                return .status(p, ["Bound", "Available"].contains(p) ? .ok : (p == "Released" ? .warning : .error))
            },
            ResourceColumn("Claim", width: .wide) { o in
                guard let n = o["spec.claimRef.name"]?.string else { return .text("–") }
                return .text("\(o["spec.claimRef.namespace"]?.string ?? "")/\(n)")
            },
            ResourceColumn("Storage Class", value: text("spec.storageClassName", "–")),
        ]
    )

    public static let storageClasses = ResourceKind(
        kind: "StorageClass", group: "storage.k8s.io", plural: "storageclasses", namespaced: false, title: "Storage Classes",
        category: .storage, symbol: "internaldrive",
        columns: [
            ResourceColumn("Provisioner", width: .wide, value: text("provisioner")),
            ResourceColumn("Reclaim Policy", value: text("reclaimPolicy", "Delete")),
            ResourceColumn("Binding Mode", value: text("volumeBindingMode", "Immediate")),
            ResourceColumn("Default", width: .narrow) { o in
                .text(o.annotations["storageclass.kubernetes.io/is-default-class"] == "true" ? "Yes" : "")
            },
        ]
    )

    // MARK: Access Control

    public static let serviceAccounts = ResourceKind(
        kind: "ServiceAccount", plural: "serviceaccounts", title: "Service Accounts", category: .accessControl, symbol: "person.crop.square"
    )

    public static let roles = ResourceKind(
        kind: "Role", group: "rbac.authorization.k8s.io", plural: "roles", title: "Roles", category: .accessControl, symbol: "person.badge.key",
        columns: [ResourceColumn("Rules", width: .narrow, value: count("rules"))]
    )

    public static let clusterRoles = ResourceKind(
        kind: "ClusterRole", group: "rbac.authorization.k8s.io", plural: "clusterroles", namespaced: false, title: "Cluster Roles",
        category: .accessControl, symbol: "person.2.badge.key",
        columns: [ResourceColumn("Rules", width: .narrow, value: count("rules"))]
    )

    public static let roleBindings = ResourceKind(
        kind: "RoleBinding", group: "rbac.authorization.k8s.io", plural: "rolebindings", title: "Role Bindings",
        category: .accessControl, symbol: "link",
        columns: [
            ResourceColumn("Role") { .text("\($0["roleRef.kind"]?.string ?? "")/\($0["roleRef.name"]?.string ?? "")") },
            ResourceColumn("Subjects", width: .wide) { .text(RBACInfo.subjects(of: $0)) },
        ]
    )

    public static let clusterRoleBindings = ResourceKind(
        kind: "ClusterRoleBinding", group: "rbac.authorization.k8s.io", plural: "clusterrolebindings", namespaced: false,
        title: "Cluster Role Bindings", category: .accessControl, symbol: "link.circle",
        columns: [
            ResourceColumn("Role") { .text("\($0["roleRef.kind"]?.string ?? "")/\($0["roleRef.name"]?.string ?? "")") },
            ResourceColumn("Subjects", width: .wide) { .text(RBACInfo.subjects(of: $0)) },
        ]
    )

    // MARK: Custom Resources

    public static let customResourceDefinitions = ResourceKind(
        kind: "CustomResourceDefinition", group: "apiextensions.k8s.io", plural: "customresourcedefinitions", namespaced: false,
        title: "Definitions", category: .customResources, symbol: "puzzlepiece.extension",
        columns: [
            ResourceColumn("Group", value: text("spec.group")),
            ResourceColumn("Kind", value: text("spec.names.kind")),
            ResourceColumn("Scope", width: .narrow, value: text("spec.scope")),
            ResourceColumn("Versions") { o in
                .text(joined((o["spec.versions"]?.array ?? []).compactMap { $0["name"]?.string }))
            },
        ]
    )

    /// All built-in kinds in sidebar order.
    public static let builtin: [ResourceKind] = [
        .nodes, .namespaces, .events,
        .pods, .deployments, .daemonSets, .statefulSets, .replicaSets, .jobs, .cronJobs,
        .configMaps, .secrets, .resourceQuotas, .limitRanges, .horizontalPodAutoscalers, .podDisruptionBudgets,
        .priorityClasses, .leases, .mutatingWebhooks, .validatingWebhooks,
        .services, .endpoints, .ingresses, .ingressClasses, .networkPolicies,
        .persistentVolumeClaims, .persistentVolumes, .storageClasses,
        .serviceAccounts, .clusterRoles, .roles, .clusterRoleBindings, .roleBindings,
        .customResourceDefinitions,
    ]

    /// Looks up a built-in kind by its `kind` name (e.g. for owner references).
    public static func builtin(kind: String) -> ResourceKind? {
        builtin.first { $0.kind == kind }
    }
}

// MARK: - Info helpers

public enum WorkloadInfo {
    /// Pod template of a Deployment/StatefulSet/DaemonSet/ReplicaSet/Job or CronJob.
    public static func podTemplate(of o: KubeObject) -> JSONValue? {
        o["spec.template"] ?? o["spec.jobTemplate.spec.template"]
    }

    public static func images(of o: KubeObject) -> [String] {
        let containers = podTemplate(of: o)?.value(at: "spec.containers")?.array ?? o["spec.containers"]?.array ?? []
        return containers.compactMap { $0["image"]?.string }
    }

    /// Label selector string for finding the pods of a workload.
    public static func selector(of o: KubeObject) -> String? {
        if o.kind == "Service" {
            let sel = o["spec.selector"]?.stringMap ?? [:]
            return sel.isEmpty ? nil : sel.map { "\($0)=\($1)" }.sorted().joined(separator: ",")
        }
        guard let sel = o["spec.selector"] else { return nil }
        var parts = (sel["matchLabels"]?.stringMap ?? [:]).map { "\($0)=\($1)" }.sorted()
        for expr in sel["matchExpressions"]?.array ?? [] {
            guard let key = expr["key"]?.string, let op = expr["operator"]?.string else { continue }
            let values = (expr["values"]?.array ?? []).compactMap(\.string).joined(separator: ",")
            switch op {
            case "In": parts.append("\(key) in (\(values))")
            case "NotIn": parts.append("\(key) notin (\(values))")
            case "Exists": parts.append(key)
            case "DoesNotExist": parts.append("!\(key)")
            default: break
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: ",")
    }
}

public enum JobInfo {
    public static func status(of o: KubeObject) -> (text: String, tone: StatusTone) {
        for c in o.conditions where c.status == "True" {
            if c.type == "Complete" { return ("Complete", .ok) }
            if c.type == "Failed" { return ("Failed", .error) }
            if c.type == "Suspended" { return ("Suspended", .warning) }
        }
        return ("Running", .progress)
    }
}

public enum ServiceInfo {
    public static func ports(of o: KubeObject) -> String {
        let ports = (o["spec.ports"]?.array ?? []).map { p -> String in
            var s = "\(p["port"]?.int ?? 0)"
            if let np = p["nodePort"]?.int { s += ":\(np)" }
            s += "/\(p["protocol"]?.string ?? "TCP")"
            return s
        }
        return ports.isEmpty ? "–" : ports.joined(separator: ", ")
    }

    public static func externalAddresses(of o: KubeObject) -> [String] {
        let lb = (o["status.loadBalancer.ingress"]?.array ?? []).compactMap { $0["ip"]?.string ?? $0["hostname"]?.string }
        let ext = (o["spec.externalIPs"]?.array ?? []).compactMap(\.string)
        if let name = o["spec.externalName"]?.string { return [name] }
        return lb + ext
    }
}

public enum RBACInfo {
    public static func subjects(of o: KubeObject) -> String {
        let s = (o["subjects"]?.array ?? []).map { subj in
            "\(subj["kind"]?.string ?? "")/\(subj["namespace"]?.string.map { "\($0)/" } ?? "")\(subj["name"]?.string ?? "")"
        }
        return s.isEmpty ? "–" : s.joined(separator: ", ")
    }
}

public enum EventInfo {
    public static func lastSeen(_ o: KubeObject) -> Date? {
        let candidates = ["lastTimestamp", "eventTime", "series.lastObservedTime", "firstTimestamp", "metadata.creationTimestamp"]
        for path in candidates {
            if let d = o[path]?.string.flatMap(KubeDate.parse) { return d }
        }
        return nil
    }
}
