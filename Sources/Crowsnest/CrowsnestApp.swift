import AppKit
import CrowsnestUI
import SwiftUI
#if canImport(CrowsnestPro)
import CrowsnestPro  // closed-source extension, only present in the official Altiros build
#endif

@main
struct CrowsnestApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        #if canImport(CrowsnestPro)
        ProExtension.register()
        #endif
    }

    var body: some Scene {
        WindowGroup("Crowsnest") {
            RootView()
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1400, height: 860)
        .commands {
            SidebarCommands()
            InspectorCommands()
            HelpCommands()
        }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when started via `swift run` (no .app bundle): show in Dock and take focus.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
