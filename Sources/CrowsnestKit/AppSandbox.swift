import Foundation

/// Whether the app runs in the App Sandbox (iPadOS always; macOS when distributed through the Mac App Store).
/// Sandboxed, Crowsnest can't read `~/.kube` or run external tools (exec auth plugins), so kubeconfigs are
/// imported into the app container instead – the same as on the iPad.
public enum AppSandbox {
    public static let isActive: Bool = {
        #if os(macOS)
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        #else
        true
        #endif
    }()
}
