import CrowsnestKit
import SwiftTerm
import SwiftUI

/// Hosts the session's (long-lived) terminal view.
struct TerminalHostView {
    let session: TerminalSession
}

#if os(macOS)
extension TerminalHostView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if session.terminalView.superview !== container { attach(to: container) }
    }

    @MainActor private func attach(to container: NSView) {
        let view = session.terminalView
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    }
}
#else
extension TerminalHostView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        attach(to: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        if session.terminalView.superview !== container { attach(to: container) }
    }

    @MainActor private func attach(to container: UIView) {
        let view = session.terminalView
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        DispatchQueue.main.async { _ = view.becomeFirstResponder() }
    }
}
#endif

/// Terminal tab content: status bar plus terminal.
struct TerminalTabView: View {
    @Environment(ClusterModel.self) private var model
    let session: TerminalSession

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                switch session.state {
                case .connecting:
                    ProgressView().controlSize(.small)
                    Text("Connecting…")
                case .connected:
                    StatusDot(tone: .ok)
                    Text("Connected")
                case .exited(let code, _):
                    StatusDot(tone: .neutral)
                    Text(code.map { "Exited (\($0))" } ?? "Exited")
                case .failed(let message):
                    StatusDot(tone: .error)
                    Text(message).lineLimit(1).help(message)
                }
                Text("·").foregroundStyle(.tertiary)
                Label(session.namespace, systemImage: "square.stack.3d.up")
                if let context = session.contextName, context != model.contextName {
                    Label(context, systemImage: "server.rack")
                }
                Spacer()
                if !session.isRunning {
                    Button("Reconnect", systemImage: "arrow.clockwise") { session.connect() }
                }
                Button("Show Pod", systemImage: "cube") {
                    model.reveal(kind: .pods, name: session.pod, namespace: session.namespace)
                }
                .disabled(session.contextName != model.contextName)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.bar)
            TerminalHostView(session: session)
        }
    }
}

struct TerminalTabButton: View {
    @Environment(ClusterModel.self) private var model
    let session: TerminalSession
    let isActive: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "terminal").font(.caption)
                .foregroundStyle(session.isRunning ? Color.secondary : Color.secondary.opacity(0.5))
            Text(session.title).lineLimit(1).font(.callout)
                .foregroundStyle(session.isRunning ? Color.primary : Color.secondary)
            Button {
                model.closeTerminal(session)
            } label: {
                Image(systemName: "xmark").font(.caption2.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .opacity(isHovering || isActive ? 1 : 0)
            .frame(width: 14, height: 14)
            .help("Close")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isActive ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture { model.activeDockTabID = session.id }
        .onHover { isHovering = $0 }
        .help("Shell in \(session.title) (\(session.namespace))")
    }
}

/// "Open Shell" entries for a pod (one per running container).
struct ShellMenuItems: View {
    @Environment(ClusterModel.self) private var model
    let pod: KubeObject

    var body: some View {
        let containers = model.shellContainers(of: pod)
        if containers.count > 1 {
            Menu("Open Shell", systemImage: "terminal") {
                ForEach(containers, id: \.self) { name in
                    Button(name) { model.openShell(pod: pod, container: name) }
                }
            }
        } else {
            Button("Open Shell", systemImage: "terminal") { model.openShell(pod: pod, container: containers.first) }
                .disabled(containers.isEmpty)
        }
    }
}
