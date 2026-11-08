import CrowsnestKit
import SwiftUI

/// "Overview" tab: metadata, kind-specific details, conditions.
struct ObjectOverviewView: View {
    @Environment(ClusterModel.self) private var model
    let object: KubeObject
    let kind: ResourceKind

    var body: some View {
        Form {
            metadataSection
            kindSpecific
            if !object.conditions.isEmpty {
                Section("Conditions") {
                    ForEach(object.conditions) { c in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                StatusDot(tone: conditionTone(c))
                                Text(c.type).fontWeight(.medium)
                                Text(c.status).foregroundStyle(.secondary)
                                Spacer()
                                if let r = c.reason { Text(r).font(.caption).foregroundStyle(.secondary) }
                                Text(KubeDate.age(since: c.lastTransition)).font(.caption).foregroundStyle(.tertiary)
                            }
                            if let m = c.message, !m.isEmpty {
                                Text(m).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func conditionTone(_ c: KubeObject.Condition) -> StatusTone {
        // For "pressure"-style conditions True is bad.
        let negative = c.type.hasSuffix("Pressure") || c.type == "NetworkUnavailable" || c.type == "Failed"
        switch c.status {
        case "True": return negative ? .warning : .ok
        case "False": return negative ? .ok : .warning
        default: return .neutral
        }
    }

    // MARK: Metadata

    @ViewBuilder
    private var metadataSection: some View {
        Section("Metadata") {
            Row("Created", "\(object.creationTimestamp?.formatted(date: .abbreviated, time: .shortened) ?? "–") (\(KubeDate.age(since: object.creationTimestamp)))")
            if let ns = object.namespace { Row("Namespace", ns) }
            if let uid = object.uid { Row("UID", uid, monospaced: true) }
            ForEach(Array(object.ownerReferences.enumerated()), id: \.offset) { _, ref in
                LabeledContent("Owner") {
                    Button("\(ref["kind"]?.string ?? "")/\(ref["name"]?.string ?? "")") {
                        model.reveal(kindName: ref["kind"]?.string ?? "", apiVersion: ref["apiVersion"]?.string,
                                     name: ref["name"]?.string ?? "", namespace: object.namespace)
                    }
                    .linkButtonStyle()
                }
            }
            if !object.labels.isEmpty {
                LabeledContent("Labels") {
                    ChipList(items: object.labels.map { "\($0)=\($1)" }.sorted())
                }
            }
            let annotations = object.annotations.filter { $0.key != "kubectl.kubernetes.io/last-applied-configuration" }
            if !annotations.isEmpty {
                DisclosureGroup("Annotations (\(annotations.count))") {
                    ForEach(annotations.keys.sorted(), id: \.self) { key in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(key).font(.caption).foregroundStyle(.secondary)
                            Text(annotations[key] ?? "").font(.caption.monospaced()).lineLimit(4).textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    // MARK: Kind specific

    @ViewBuilder
    private var kindSpecific: some View {
        switch object.kind {
        case "Pod": PodSections(pod: object)
        case "Deployment", "StatefulSet", "ReplicaSet", "DaemonSet": WorkloadSections(object: object)
        case "Job", "CronJob": JobSections(object: object)
        case "Service": ServiceSections(service: object)
        case "Node": NodeSections(node: object)
        case "ConfigMap": DataSection(title: "Data", data: object["data"]?.stringMap ?? [:], isSecret: false)
        case "Secret":
            Section("Type") { Row("Type", object["type"]?.string ?? "Opaque") }
            DataSection(title: "Data", data: object["data"]?.stringMap ?? [:], isSecret: true)
        case "Ingress": IngressSections(ingress: object)
        case "Role", "ClusterRole": RulesSection(object: object)
        case "RoleBinding", "ClusterRoleBinding": BindingSection(object: object)
        case "Event": EventSections(event: object)
        case "PersistentVolumeClaim":
            Section("Volume") {
                Row("Status", object["status.phase"]?.string ?? "–")
                Row("Volume", object["spec.volumeName"]?.string ?? "–")
                Row("Capacity", object["status.capacity.storage"]?.string ?? object["spec.resources.requests.storage"]?.string ?? "–")
                Row("Storage Class", object["spec.storageClassName"]?.string ?? "–")
                Row("Access Modes", (object["spec.accessModes"]?.array ?? []).compactMap(\.string).joined(separator: ", "))
            }
        default:
            if kind.category == .customResources || !kind.columns.isEmpty {
                Section("Fields") {
                    ForEach(kind.columns) { column in
                        Row(column.title, column.value(object).display())
                    }
                }
            }
        }
    }
}

// MARK: - Building blocks

struct Row: View {
    var label: String
    var value: String
    var monospaced = false

    init(_ label: String, _ value: String, monospaced: Bool = false) {
        self.label = label
        self.value = value
        self.monospaced = monospaced
    }

    var body: some View {
        LabeledContent(label) {
            Text(value.isEmpty ? "–" : value)
                .font(monospaced ? .callout.monospaced() : .callout)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
    }
}

struct PodSections: View {
    @Environment(ClusterModel.self) private var model
    let pod: KubeObject

    var body: some View {
        let status = PodStatus.status(of: pod)
        Section("Status") {
            LabeledContent("Status") { StatusLabel(text: status.text, tone: status.tone) }
            if let node = pod["spec.nodeName"]?.string {
                LabeledContent("Node") {
                    Button(node) { model.reveal(kind: .nodes, name: node, namespace: nil) }.linkButtonStyle()
                }
            }
            Row("Pod IP", (pod["status.podIPs"]?.array ?? []).compactMap { $0["ip"]?.string }.joined(separator: ", "))
            Row("QoS", pod["status.qosClass"]?.string ?? "–")
            Row("Service Account", pod["spec.serviceAccountName"]?.string ?? "–")
            Row("Restarts", String(PodStatus.restarts(of: pod)))
        }
        if let usage = model.metrics.pod(pod.namespace, pod.name)?.total {
            let spec = ResourceSpec.of(pod: pod)
            Section("Usage") {
                UsageMeterRow(resource: .cpu, used: usage.cpu, request: spec.cpuRequest, limit: spec.cpuLimit)
                UsageMeterRow(resource: .memory, used: usage.memory, request: spec.memoryRequest, limit: spec.memoryLimit)
            }
            UsageChartsSection(title: "History", samples: model.metrics.history(pod: pod.name, namespace: pod.namespace), spec: spec)
        }
        let statuses = (pod["status.containerStatuses"]?.array ?? []) + (pod["status.initContainerStatuses"]?.array ?? [])
        ForEach(Array(((pod["spec.initContainers"]?.array ?? []).map { ($0, true) } + (pod["spec.containers"]?.array ?? []).map { ($0, false) }).enumerated()), id: \.offset) { _, entry in
            let (container, isInit) = entry
            let name = container["name"]?.string ?? "?"
            let cs = statuses.first { $0["name"]?.string == name }
            ContainerSection(pod: pod, container: container, status: cs, isInit: isInit)
        }
    }
}

struct ContainerSection: View {
    @Environment(ClusterModel.self) private var model
    let pod: KubeObject
    let container: JSONValue
    let status: JSONValue?
    let isInit: Bool

    var body: some View {
        Section {
            Row("Image", container["image"]?.string ?? "–", monospaced: true)
            if let state = status?["state"]?.object?.first {
                let reason = state.value["reason"]?.string
                Row("State", [state.key, reason].compactMap { $0 }.joined(separator: " – "))
            }
            if let status {
                Row("Ready", status["ready"]?.bool == true ? "Yes" : "No")
                Row("Restarts", String(status["restartCount"]?.int ?? 0))
                if let last = status["lastState"]?["terminated"] {
                    Row("Last Termination", "\(last["reason"]?.string ?? "") (Exit \(last["exitCode"]?.int ?? 0))")
                }
            }
            ForEach(Array((container["ports"]?.array ?? []).enumerated()), id: \.offset) { _, p in
                let number = p["containerPort"]?.int ?? 0
                let proto = p["protocol"]?.string ?? "TCP"
                LabeledContent(p["name"]?.string.map { "Port \($0)" } ?? "Port") {
                    HStack(spacing: 8) {
                        Text("\(String(number))/\(proto)").monospacedDigit()
                        if proto == "TCP" && !isInit && isRunning {
                            PortForwardButton(object: pod, port: number, portName: p["name"]?.string)
                        }
                    }
                }
            }
            if !isInit, let usage = model.metrics.pod(pod.namespace, pod.name)?.containers[container["name"]?.string ?? ""] {
                let spec = ResourceSpec.of(container: container)
                UsageMeterRow(resource: .cpu, used: usage.cpu, request: spec.cpuRequest, limit: spec.cpuLimit)
                UsageMeterRow(resource: .memory, used: usage.memory, request: spec.memoryRequest, limit: spec.memoryLimit)
            } else if let r = container["resources"], let text = resourcesText(r) {
                Row("Resources", text)
            }
            if let cmd = container["command"]?.array {
                Row("Command", (cmd + (container["args"]?.array ?? [])).compactMap(\.string).joined(separator: " "), monospaced: true)
            }
        } header: {
            HStack {
                Text(container["name"]?.string ?? "Container")
                if isInit { Text("init").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if !isInit && isRunning {
                    Button("Shell", systemImage: "terminal") {
                        model.openShell(pod: pod, container: container["name"]?.string)
                    }
                    .linkButtonStyle()
                    .font(.caption)
                    .help("Open a shell in this container")
                }
            }
        }
    }

    private var isRunning: Bool { status?.value(at: "state.running") != nil }

    private func resourcesText(_ r: JSONValue) -> String? {
        var parts: [String] = []
        if let req = r["requests"]?.stringMap, !req.isEmpty {
            parts.append("Requests: " + req.sorted { $0.key < $1.key }.map { "\($0)=\($1)" }.joined(separator: ", "))
        }
        if let lim = r["limits"]?.stringMap, !lim.isEmpty {
            parts.append("Limits: " + lim.sorted { $0.key < $1.key }.map { "\($0)=\($1)" }.joined(separator: ", "))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
}

struct WorkloadSections: View {
    @Environment(ClusterModel.self) private var model
    let object: KubeObject

    var body: some View {
        Section("Replicas") {
            switch object.kind {
            case "DaemonSet":
                Row("Desired", String(object["status.desiredNumberScheduled"]?.int ?? 0))
                Row("Ready", String(object["status.numberReady"]?.int ?? 0))
                Row("Up to Date", String(object["status.updatedNumberScheduled"]?.int ?? 0))
            default:
                Row("Desired", String(object["spec.replicas"]?.int ?? 0))
                Row("Ready", String(object["status.readyReplicas"]?.int ?? 0))
                if object.kind != "ReplicaSet" { Row("Up to Date", String(object["status.updatedReplicas"]?.int ?? 0)) }
                Row("Available", String(object["status.availableReplicas"]?.int ?? 0))
            }
            if let strategy = object["spec.strategy.type"]?.string ?? object["spec.updateStrategy.type"]?.string {
                Row("Strategy", strategy)
            }
            if let selector = WorkloadInfo.selector(of: object) {
                LabeledContent("Selector") { ChipList(items: selector.components(separatedBy: ",")) }
            }
            Row("Images", WorkloadInfo.images(of: object).joined(separator: "\n"), monospaced: true)
        }
        let keys = model.podKeys(of: object, in: model.workloadPods)
        if !keys.isEmpty, let usage = model.metrics.usage(ofPods: keys) {
            Section("Usage (\(keys.count) pods)") {
                Row("CPU", Quantity.formatCPU(usage.cpu))
                Row("Memory", Quantity.formatBytes(usage.memory))
            }
            UsageChartsSection(title: "History (all pods)", samples: model.metrics.history(pods: keys))
        }
        if let selector = WorkloadInfo.selector(of: object) {
            RelatedPodsSection(labelSelector: selector, namespace: object.namespace)
        }
    }
}

struct JobSections: View {
    let object: KubeObject

    var body: some View {
        if object.kind == "CronJob" {
            Section("Schedule") {
                Row("Schedule", object["spec.schedule"]?.string ?? "–", monospaced: true)
                Row("Time Zone", object["spec.timeZone"]?.string ?? "Controller time zone")
                Row("Suspended", object["spec.suspend"]?.bool == true ? "Yes" : "No")
                Row("Last Schedule", KubeDate.age(since: object["status.lastScheduleTime"]?.string.flatMap(KubeDate.parse)))
                Row("Active Jobs", String(object["status.active"]?.array?.count ?? 0))
                Row("Images", WorkloadInfo.images(of: object).joined(separator: "\n"), monospaced: true)
            }
        } else {
            let status = JobInfo.status(of: object)
            Section("Job") {
                LabeledContent("Status") { StatusLabel(text: status.text, tone: status.tone) }
                Row("Completions", "\(object["status.succeeded"]?.int ?? 0)/\(object["spec.completions"]?.int ?? 1)")
                Row("Failed", String(object["status.failed"]?.int ?? 0))
                Row("Started", object["status.startTime"]?.string.flatMap(KubeDate.parse)?.formatted() ?? "–")
                Row("Completed", object["status.completionTime"]?.string.flatMap(KubeDate.parse)?.formatted() ?? "–")
            }
            if let uid = object.uid {
                RelatedPodsSection(labelSelector: "batch.kubernetes.io/controller-uid=\(uid)", namespace: object.namespace)
            }
        }
    }
}

struct ServiceSections: View {
    let service: KubeObject

    var body: some View {
        Section("Service") {
            Row("Type", service["spec.type"]?.string ?? "ClusterIP")
            Row("Cluster IP", (service["spec.clusterIPs"]?.array ?? []).compactMap(\.string).joined(separator: ", "))
            let external = ServiceInfo.externalAddresses(of: service)
            if !external.isEmpty { Row("External", external.joined(separator: ", ")) }
            Row("Session Affinity", service["spec.sessionAffinity"]?.string ?? "None")
        }
        Section("Ports") {
            ForEach(Array((service["spec.ports"]?.array ?? []).enumerated()), id: \.offset) { _, p in
                let port = p["port"]?.int ?? 0
                let proto = p["protocol"]?.string ?? "TCP"
                let target = p["targetPort"]?.int.map { String($0) } ?? p["targetPort"]?.string ?? String(port)
                LabeledContent(p["name"]?.string ?? "Port") {
                    HStack(spacing: 8) {
                        Text("\(String(port)) → \(target)/\(proto)\(p["nodePort"]?.int.map { " (NodePort \(String($0)))" } ?? "")")
                            .monospacedDigit()
                        if proto == "TCP" && service["spec.selector"] != nil {
                            PortForwardButton(object: service, port: port, portName: p["name"]?.string)
                        }
                    }
                }
            }
        }
        if let selector = WorkloadInfo.selector(of: service) {
            RelatedPodsSection(labelSelector: selector, namespace: service.namespace)
        }
    }
}

struct NodeSections: View {
    @Environment(ClusterModel.self) private var model
    let node: KubeObject
    private var usage: ResourceUsage? { model.metrics.nodes?[node.name] }

    var body: some View {
        let status = NodeStatus.status(of: node)
        Section("Node") {
            LabeledContent("Status") { StatusLabel(text: status.text, tone: status.tone) }
            Row("Roles", NodeStatus.roles(of: node))
            ForEach((node["status.addresses"]?.array ?? []).indices, id: \.self) { i in
                let a = node["status.addresses"]!.array![i]
                Row(a["type"]?.string ?? "", a["address"]?.string ?? "")
            }
            Row("Kubelet", node["status.nodeInfo.kubeletVersion"]?.string ?? "–")
            Row("OS Image", node["status.nodeInfo.osImage"]?.string ?? "–")
            Row("Kernel", node["status.nodeInfo.kernelVersion"]?.string ?? "–")
            Row("Container Runtime", node["status.nodeInfo.containerRuntimeVersion"]?.string ?? "–")
            Row("Architecture", node["status.nodeInfo.architecture"]?.string ?? "–")
        }
        Section("Resources") {
            let cpu = node["status.allocatable.cpu"]?.string.flatMap(Quantity.parse) ?? 0
            let mem = node["status.allocatable.memory"]?.string.flatMap(Quantity.parse) ?? 0
            if let usage {
                UsageBar(title: "CPU", used: usage.cpu, capacity: cpu, format: Quantity.formatCPU)
                UsageBar(title: "Memory", used: usage.memory, capacity: mem, format: Quantity.formatBytes)
            } else {
                Row("CPU (allocatable)", Quantity.formatCPU(cpu))
                Row("Memory (allocatable)", Quantity.formatBytes(mem))
            }
            Row("Pods (max)", node["status.allocatable.pods"]?.string ?? "–")
        }
        if usage != nil {
            UsageChartsSection(title: "History", samples: model.metrics.history(node: node.name),
                               spec: ResourceSpec(cpuLimit: node["status.allocatable.cpu"]?.string.flatMap(Quantity.parse),
                                                  memoryLimit: node["status.allocatable.memory"]?.string.flatMap(Quantity.parse)),
                               limitLabel: "allocatable")
        }
        let taints = (node["spec.taints"]?.array ?? []).map { t in
            "\(t["key"]?.string ?? "")\(t["value"]?.string.map { "=\($0)" } ?? ""):\(t["effect"]?.string ?? "")"
        }
        if !taints.isEmpty {
            Section("Taints") { ChipList(items: taints) }
        }
        RelatedPodsSection(fieldSelector: "spec.nodeName=\(node.name)", namespace: nil)
    }
}

struct IngressSections: View {
    @Environment(ClusterModel.self) private var model
    let ingress: KubeObject

    var body: some View {
        Section("Rules") {
            ForEach(Array((ingress["spec.rules"]?.array ?? []).enumerated()), id: \.offset) { _, rule in
                let host = rule["host"]?.string ?? "*"
                ForEach(Array((rule.value(at: "http.paths")?.array ?? []).enumerated()), id: \.offset) { _, path in
                    let svc = path.value(at: "backend.service.name")?.string ?? "?"
                    let port = path.value(at: "backend.service.port.number")?.string ?? path.value(at: "backend.service.port.name")?.string ?? ""
                    LabeledContent("\(host)\(path["path"]?.string ?? "/")") {
                        Button("\(svc):\(port)") { model.reveal(kind: .services, name: svc, namespace: ingress.namespace) }
                            .linkButtonStyle()
                    }
                }
            }
        }
        let tls = (ingress["spec.tls"]?.array ?? [])
        if !tls.isEmpty {
            Section("TLS") {
                ForEach(Array(tls.enumerated()), id: \.offset) { _, t in
                    Row(t["secretName"]?.string ?? "–", (t["hosts"]?.array ?? []).compactMap(\.string).joined(separator: ", "))
                }
            }
        }
    }
}

struct DataSection: View {
    let title: String
    let data: [String: String]
    let isSecret: Bool
    @State private var revealed: Set<String> = []

    var body: some View {
        Section("\(title) (\(data.count))") {
            ForEach(data.keys.sorted(), id: \.self) { key in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(key).font(.callout.weight(.medium))
                        Spacer()
                        if isSecret {
                            Button(revealed.contains(key) ? "Hide" : "Show") {
                                if revealed.contains(key) { revealed.remove(key) } else { revealed.insert(key) }
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                        }
                        Button("Copy", systemImage: "doc.on.doc") { Pasteboard.copy(value(for: key)) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                    }
                    if !isSecret || revealed.contains(key) {
                        Text(value(for: key))
                            .font(.caption.monospaced())
                            .lineLimit(30)
                            .textSelection(.enabled)
                    } else {
                        Text("••••••••").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func value(for key: String) -> String {
        let raw = data[key] ?? ""
        guard isSecret else { return raw }
        guard let decoded = Data(base64Encoded: raw) else { return raw }
        return String(data: decoded, encoding: .utf8) ?? "<\(decoded.count) bytes binary>"
    }
}

struct RulesSection: View {
    let object: KubeObject
    var body: some View {
        Section("Rules") {
            ForEach(Array((object["rules"]?.array ?? []).enumerated()), id: \.offset) { _, rule in
                VStack(alignment: .leading, spacing: 2) {
                    let resources = ((rule["resources"]?.array ?? []) + (rule["nonResourceURLs"]?.array ?? [])).compactMap(\.string)
                    Text(resources.joined(separator: ", ")).font(.callout.weight(.medium))
                    let groups = (rule["apiGroups"]?.array ?? []).compactMap(\.string).map { $0.isEmpty ? "core" : $0 }
                    if !groups.isEmpty { Text("API-Gruppen: \(groups.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary) }
                    ChipList(items: (rule["verbs"]?.array ?? []).compactMap(\.string))
                }
            }
        }
    }
}

struct BindingSection: View {
    @Environment(ClusterModel.self) private var model
    let object: KubeObject
    var body: some View {
        Section("Binding") {
            LabeledContent("Role") {
                let kindName = object["roleRef.kind"]?.string ?? ""
                let name = object["roleRef.name"]?.string ?? ""
                Button("\(kindName)/\(name)") {
                    model.reveal(kindName: kindName, name: name, namespace: kindName == "Role" ? object.namespace : nil)
                }
                .linkButtonStyle()
            }
            Row("Subjects", RBACInfo.subjects(of: object).replacingOccurrences(of: ", ", with: "\n"))
        }
    }
}

struct EventSections: View {
    @Environment(ClusterModel.self) private var model
    let event: KubeObject
    var body: some View {
        Section("Event") {
            Row("Type", event["type"]?.string ?? "")
            Row("Reason", event["reason"]?.string ?? "")
            LabeledContent("Object") {
                let kindName = event["involvedObject.kind"]?.string ?? ""
                let name = event["involvedObject.name"]?.string ?? ""
                Button("\(kindName)/\(name)") {
                    model.reveal(kindName: kindName, apiVersion: event["involvedObject.apiVersion"]?.string,
                                 name: name, namespace: event["involvedObject.namespace"]?.string)
                }
                .linkButtonStyle()
            }
            Row("Message", event["message"]?.string ?? "")
            Row("Source", event["source.component"]?.string ?? event["reportingComponent"]?.string ?? "")
            Row("Count", String(event["count"]?.int ?? 1))
            Row("Last Seen", KubeDate.age(since: EventInfo.lastSeen(event)))
        }
    }
}

/// Pods selected by a label or field selector, with click-through.
struct RelatedPodsSection: View {
    @Environment(ClusterModel.self) private var model
    var labelSelector: String?
    var fieldSelector: String?
    let namespace: String?
    @State private var pods: [KubeObject]?

    var body: some View {
        Section("Pods\(pods.map { " (\($0.count))" } ?? "")") {
            if let pods {
                if pods.isEmpty { Text("No pods").foregroundStyle(.secondary) }
                ForEach(pods.prefix(100)) { pod in
                    let status = PodStatus.status(of: pod)
                    Button {
                        model.reveal(kind: .pods, name: pod.name, namespace: pod.namespace)
                    } label: {
                        HStack {
                            StatusDot(tone: status.tone)
                            Text(pod.name).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(status.text).font(.caption).foregroundStyle(.secondary)
                            Text(KubeDate.age(since: pod.creationTimestamp)).font(.caption).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: "\(labelSelector ?? "")|\(fieldSelector ?? "")|\(model.lastRefresh?.timeIntervalSince1970 ?? 0)") {
            guard let client = model.client else { return }
            pods = try? await client.list(.pods, namespace: namespace, labelSelector: labelSelector, fieldSelector: fieldSelector)
        }
    }
}
