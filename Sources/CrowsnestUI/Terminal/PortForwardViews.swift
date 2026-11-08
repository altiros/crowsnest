import CrowsnestKit
import SwiftUI

/// Sheet to start a port forward.
struct PortForwardSheet: View {
    @Environment(ClusterModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let request: PortForwardRequest
    @State private var localPort = ""
    @State private var openInBrowser = true
    @State private var isStarting = false

    private var parsedPort: Int? { Int(localPort.trimmingCharacters(in: .whitespaces)) }
    private var isValid: Bool {
        localPort.trimmingCharacters(in: .whitespaces).isEmpty || (parsedPort.map { (1...65535).contains($0) } ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Port Forward").font(.headline)
            Text("\(request.object.kind) \"\(request.object.name)\", port \(request.port)\(request.portName.map { " (\($0))" } ?? "")")
                .foregroundStyle(.secondary)
            LabeledContent("Local port") {
                TextField("automatic", text: $localPort)
                    .frame(width: 110)
                    .multilineTextAlignment(.trailing)
                    #if !os(macOS)
                    .keyboardType(.numberPad)
                    #endif
            }
            Toggle("Open in browser", isOn: $openInBrowser)
            #if !os(macOS)
            Text("Forwards only work while Crowsnest is active – e.g. in Split View next to Safari.")
                .font(.caption).foregroundStyle(.secondary)
            #endif
            if !isValid {
                Text("Invalid port (1–65535)").font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start") {
                    isStarting = true
                    Task {
                        let entry = await model.startPortForward(request, localPort: parsedPort)
                        isStarting = false
                        dismiss()
                        if openInBrowser, let url = entry?.url { openURL(url) }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid || isStarting)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
        .onAppear {
            // Same port locally when it's unprivileged; otherwise let the system choose.
            if request.port >= 1024 { localPort = String(request.port) }
            #if !os(macOS)
            openInBrowser = false
            #endif
        }
    }
}

/// Starts a forward for a port, or shows the running one.
struct PortForwardButton: View {
    @Environment(ClusterModel.self) private var model
    @Environment(\.openURL) private var openURL
    let object: KubeObject
    let port: Int
    var portName: String?

    var body: some View {
        if let entry = model.portForward(for: object, port: port) {
            Menu {
                Button("Open in Browser", systemImage: "safari") { if let url = entry.url { openURL(url) } }
                Button("Copy Address", systemImage: "doc.on.doc") { Pasteboard.copy(entry.url?.absoluteString ?? "") }
                Divider()
                Button("Stop", systemImage: "stop.circle", role: .destructive) { model.stopPortForward(entry) }
            } label: {
                Label("localhost:\(String(entry.localPort))", systemImage: "arrow.left.arrow.right.circle.fill")
            }
            .borderlessMenuStyle()
            .fixedSize()
            .help("Port forward active")
        } else {
            Button("Forward", systemImage: "arrow.left.arrow.right") {
                model.portForwardRequest = PortForwardRequest(object: object, port: port, portName: portName)
            }
            .linkButtonStyle()
            .help("Make port \(port) available locally (port forward)")
        }
    }
}

/// "Port-Forward" entries for the actions menu of pods and services.
struct PortForwardMenuItems: View {
    @Environment(ClusterModel.self) private var model
    let object: KubeObject

    var body: some View {
        let ports = ForwardablePort.of(object)
        if ports.count == 1, let p = ports.first {
            Button("Port Forward \(String(p.port))…", systemImage: "arrow.left.arrow.right") {
                model.portForwardRequest = PortForwardRequest(object: object, port: p.port, portName: p.name)
            }
        } else if !ports.isEmpty {
            Menu("Port Forward", systemImage: "arrow.left.arrow.right") {
                ForEach(ports, id: \.self) { p in
                    Button(p.label) { model.portForwardRequest = PortForwardRequest(object: object, port: p.port, portName: p.name) }
                }
            }
        }
    }
}

/// Sidebar page listing active forwards, like Lens' "Port Forwarding".
struct PortForwardListView: View {
    @Environment(ClusterModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if model.portForwards.isEmpty {
                ContentUnavailableView {
                    Label("No Port Forwards", systemImage: "arrow.left.arrow.right")
                } description: {
                    Text("Start a forward from the ports of a pod or service – in the details panel or the actions menu.")
                }
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    List {
                        ForEach(model.portForwards) { entry in
                            row(entry)
                        }
                    }
                }
            }
        }
        .navigationTitle("Port Forwards")
    }

    private func row(_ entry: PortForwardEntry) -> some View {
        let status = entry.forwarder.status
        return HStack(spacing: 12) {
            Image(systemName: entry.targetKind == "Service" ? "point.3.connected.trianglepath.dotted" : "cube")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("\(entry.targetKind == "Service" ? "svc" : "pod")/\(entry.targetName):\(String(entry.targetPort))")
                        .font(.headline)
                    Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                    Button("localhost:\(String(entry.localPort))") { if let url = entry.url { openURL(url) } }
                        .linkButtonStyle()
                }
                HStack(spacing: 6) {
                    Text(entry.namespace)
                    if let context = entry.contextName { Text("·"); Text(context) }
                    if entry.targetKind == "Service" {
                        Text("·"); Text("via \(entry.forwarder.pod):\(String(entry.forwarder.remotePort))")
                    }
                    Text("·")
                    Text(status.activeConnections == 1 ? "1 connection" : "\(status.activeConnections) connections")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let error = status.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            Button("Open", systemImage: "safari") { if let url = entry.url { openURL(url) } }
                .labelStyle(.iconOnly)
                .help("Open in Browser")
            Button("Copy", systemImage: "doc.on.doc") { Pasteboard.copy(entry.url?.absoluteString ?? "") }
                .labelStyle(.iconOnly)
                .help("Copy Address")
            Button("Restart", systemImage: "arrow.clockwise") { Task { await model.restartPortForward(entry) } }
                .labelStyle(.iconOnly)
                .help("Restart (e.g. after the pod was replaced)")
            Button("Stop", systemImage: "stop.circle") { model.stopPortForward(entry) }
                .labelStyle(.iconOnly)
                .help("Stop")
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 4)
        .contextMenu {
            Button("Open in Browser", systemImage: "safari") { if let url = entry.url { openURL(url) } }
            Button("Copy Address", systemImage: "doc.on.doc") { Pasteboard.copy(entry.url?.absoluteString ?? "") }
            Button("Stop", systemImage: "stop.circle", role: .destructive) { model.stopPortForward(entry) }
        }
    }
}
