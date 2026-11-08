import CrowsnestKit
import Foundation
import Observation
import SwiftTerm
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A shell in a container, shown as a tab in the dock. Owns its terminal view so the
/// scrollback survives switching tabs.
@MainActor @Observable
public final class TerminalSession: Identifiable {
    public enum State: Equatable {
        case connecting
        case connected
        case exited(code: Int?, message: String?)
        case failed(String)
    }

    public let id = UUID()
    public let pod: String
    public let namespace: String
    public let container: String?
    public let contextName: String?
    public private(set) var state: State = .connecting
    public private(set) var remoteTitle: String?

    @ObservationIgnored private let client: KubeClient
    @ObservationIgnored private var exec: ExecSession?
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var size = (columns: 80, rows: 24)
    @ObservationIgnored public private(set) lazy var terminalView: TerminalView = makeTerminalView()

    init(client: KubeClient, pod: String, namespace: String, container: String?, contextName: String?) {
        self.client = client
        self.pod = pod
        self.namespace = namespace
        self.container = container
        self.contextName = contextName
    }

    public var title: String { container.map { "\(pod)/\($0)" } ?? pod }

    public var isRunning: Bool { state == .connecting || state == .connected }

    /// Starts (or restarts) the shell.
    public func connect() {
        let isReconnect = readTask != nil
        readTask?.cancel()
        exec?.close()
        exec = nil
        state = .connecting
        let view = terminalView
        if isReconnect { showBanner("Reconnecting…") }
        readTask = Task { [weak self, client, pod, namespace, container, size] in
            do {
                let session = try await client.exec(pod: pod, namespace: namespace, container: container,
                                                     columns: size.columns, rows: size.rows)
                guard let self, !Task.isCancelled else { session.close(); return }
                self.exec = session
                self.state = .connected
                for try await event in session.events {
                    switch event {
                    case .output(let bytes):
                        view.feed(byteArray: bytes[...])
                    case .exited(let code, let message):
                        self.state = .exited(code: code, message: message)
                    }
                }
                if self.state == .connected { self.state = .exited(code: nil, message: nil) }
                self.showBanner(self.exitBanner)
            } catch is CancellationError {
            } catch {
                guard let self else { return }
                self.state = .failed(error.localizedDescription)
                self.showBanner("Connection failed: \(error.localizedDescription)")
            }
        }
    }

    public func close() {
        readTask?.cancel()
        exec?.close()
        exec = nil
    }

    private var exitBanner: String {
        if case .exited(let code, let message) = state {
            if let message { return "Session ended: \(message)" }
            return code.map { "Session ended (exit code \($0))" } ?? "Session ended"
        }
        return "Session ended"
    }

    private func showBanner(_ text: String) {
        // Dim, on its own line, like Lens.
        terminalView.feed(text: "\r\n\u{1B}[2m[\(text)]\u{1B}[0m\r\n")
    }

    private func makeTerminalView() -> TerminalView {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
        #if os(macOS)
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        // Option must produce characters (| @ [ ] { } ~ on German keyboards), not act as Meta.
        view.optionAsMetaKey = false
        #else
        view.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        #endif
        view.terminalDelegate = self
        return view
    }
}

extension TerminalSession: @preconcurrency TerminalViewDelegate {
    public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        exec?.write(data)
    }

    public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        size = (newCols, newRows)
        exec?.resize(columns: newCols, rows: newRows)
    }

    public func setTerminalTitle(source: TerminalView, title: String) {
        remoteTitle = title.isEmpty ? nil : title
    }

    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    public func scrolled(source: TerminalView, position: Double) {}
    public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
