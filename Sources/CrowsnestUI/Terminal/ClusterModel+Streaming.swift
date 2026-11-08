import CrowsnestKit
import Foundation

/// An active port forward as shown in the "Port-Forwards" list.
public struct PortForwardEntry: Identifiable {
    public let forwarder: PortForwarder
    public let request: PortForwardRequest
    public let contextName: String?

    /// "Pod" or "Service".
    public var targetKind: String { request.object.kind }
    public var targetName: String { request.object.name }
    /// The port the user picked (service port for services, container port for pods).
    public var targetPort: Int { request.port }

    public var id: UUID { forwarder.id }
    public var namespace: String { forwarder.namespace }
    public var localPort: Int { forwarder.localPort }
    public var url: URL? { forwarder.url }

    func matches(_ object: KubeObject, port: Int, context: String?) -> Bool {
        targetKind == object.kind && targetName == object.name && namespace == object.namespace
            && targetPort == port && contextName == context
    }
}

/// Request to start a port forward (presented as a sheet).
public struct PortForwardRequest: Identifiable {
    public let object: KubeObject
    public let port: Int
    public let portName: String?
    public var id: String { "\(object.id):\(port)" }
}

/// A TCP port declared by a pod's containers or a service.
struct ForwardablePort: Hashable {
    var port: Int
    var name: String?
    var container: String?

    var label: String {
        var text = String(port)
        if let name { text += " (\(name))" }
        if let container { text += " · \(container)" }
        return text
    }

    static func of(_ object: KubeObject) -> [ForwardablePort] {
        switch object.kind {
        case "Pod":
            return (object["spec.containers"]?.array ?? []).flatMap { container in
                (container["ports"]?.array ?? []).compactMap { p -> ForwardablePort? in
                    guard (p["protocol"]?.string ?? "TCP") == "TCP", let port = p["containerPort"]?.int else { return nil }
                    return ForwardablePort(port: port, name: p["name"]?.string, container: container["name"]?.string)
                }
            }
        case "Service":
            return (object["spec.ports"]?.array ?? []).compactMap { p in
                guard (p["protocol"]?.string ?? "TCP") == "TCP", let port = p["port"]?.int else { return nil }
                return ForwardablePort(port: port, name: p["name"]?.string)
            }
        default:
            return []
        }
    }
}

extension ClusterModel {
    // MARK: - Shell

    /// Containers of a pod that a shell can be opened in (running, not init containers).
    func shellContainers(of pod: KubeObject) -> [String] {
        let running = Set((pod["status.containerStatuses"]?.array ?? [])
            .filter { $0.value(at: "state.running") != nil }
            .compactMap { $0["name"]?.string })
        return (pod["spec.containers"]?.array ?? []).compactMap { $0["name"]?.string }.filter { running.contains($0) }
    }

    /// Opens a shell tab for a container (or focuses an existing running one).
    public func openShell(pod: KubeObject, container: String?) {
        guard let client, let namespace = pod.namespace else { return }
        let container = container ?? shellContainers(of: pod).first
        isEditorVisible = true
        if let existing = terminals.first(where: {
            $0.pod == pod.name && $0.namespace == namespace && $0.container == container && $0.contextName == contextName && $0.isRunning
        }) {
            activeDockTabID = existing.id
            return
        }
        let session = TerminalSession(client: client, pod: pod.name, namespace: namespace, container: container,
                                      contextName: contextName)
        terminals.append(session)
        activeDockTabID = session.id
        session.connect()
    }

    public func closeTerminal(_ session: TerminalSession) {
        session.close()
        guard let index = terminals.firstIndex(where: { $0.id == session.id }) else { return }
        terminals.remove(at: index)
        if activeDockTabID == session.id {
            activeDockTabID = terminals.indices.contains(index) ? terminals[index].id : (terminals.last?.id ?? editorTabs.last?.id)
        }
        if editorTabs.isEmpty && terminals.isEmpty { isEditorVisible = false }
    }

    // MARK: - Port forwarding

    func portForward(for object: KubeObject, port: Int) -> PortForwardEntry? {
        portForwards.first { $0.matches(object, port: port, context: contextName) }
    }

    /// Starts forwarding `localPort` (nil = any free port) to a pod or service port.
    @discardableResult
    public func startPortForward(_ request: PortForwardRequest, localPort: Int?) async -> PortForwardEntry? {
        guard let client, let namespace = request.object.namespace else { return nil }
        do {
            let target: (pod: String, port: Int)
            if request.object.kind == "Service" {
                target = try await client.forwardTarget(service: request.object, port: request.port)
            } else {
                target = (request.object.name, request.port)
            }
            let forwarder = try await client.forward(pod: target.pod, namespace: namespace, remotePort: target.port,
                                                     localPort: localPort ?? 0)
            let entry = PortForwardEntry(forwarder: forwarder, request: request, contextName: contextName)
            portForwards.append(entry)
            toast = "Forwarding localhost:\(forwarder.localPort) → \(request.object.name):\(request.port)"
            return entry
        } catch {
            alertMessage = "Port forward failed: \(error.localizedDescription)"
            return nil
        }
    }

    public func stopPortForward(_ entry: PortForwardEntry) {
        entry.forwarder.stop()
        portForwards.removeAll { $0.id == entry.id }
    }

    /// Restarts on the same local port, e.g. after the pod behind a service was replaced.
    public func restartPortForward(_ entry: PortForwardEntry) async {
        guard entry.contextName == contextName else {
            alertMessage = "Switch to context \"\(entry.contextName ?? "")\" first."
            return
        }
        let index = portForwards.firstIndex { $0.id == entry.id }
        stopPortForward(entry)
        try? await Task.sleep(for: .milliseconds(100))
        // Keep the row where it was.
        if let new = await startPortForward(entry.request, localPort: entry.localPort), let index,
           let position = portForwards.firstIndex(where: { $0.id == new.id }) {
            portForwards.remove(at: position)
            portForwards.insert(new, at: min(index, portForwards.count))
        }
    }
}
