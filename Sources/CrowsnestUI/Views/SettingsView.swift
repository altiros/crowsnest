import CrowsnestKit
import SwiftUI

public struct SettingsView: View {
    @AppStorage(SettingsKey.refreshInterval) private var refreshInterval: Double = 5
    @AppStorage(SettingsKey.kubeconfigPath) private var kubeconfigPath: String = ""
    @AppStorage(SettingsKey.appearance) private var appearance = "system"

    public init() {}

    public var body: some View {
        Form {
            Section("General") {
                Picker("Auto refresh", selection: $refreshInterval) {
                    Text("Off").tag(0.0)
                    Text("Every 2 seconds").tag(2.0)
                    Text("Every 5 seconds").tag(5.0)
                    Text("Every 10 seconds").tag(10.0)
                    Text("Every 30 seconds").tag(30.0)
                }
                Picker("Appearance", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
            }
            ExtensionSettingsSections()
            #if os(macOS)
            Section {
                TextField("kubeconfig", text: $kubeconfigPath, prompt: Text(defaultPath))
                #if os(macOS)
                HStack {
                    Button("Choose…") { choose() }
                    if !kubeconfigPath.isEmpty { Button("Use Default") { kubeconfigPath = "" } }
                }
                #endif
            } header: {
                Text("kubeconfig")
            } footer: {
                Text("Leave empty for $KUBECONFIG or ~/.kube/config. Separate multiple files with \":\". Changes apply after \"Reload kubeconfig\".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #else
            KubeconfigFilesSection()
            HelpSection()
            #endif
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 260)
        #endif
    }

    private var defaultPath: String {
        KubeConfig.defaultFileURLs().map(\.path).joined(separator: ":")
    }

    #if os(macOS)
    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".kube")
        if panel.runModal() == .OK {
            kubeconfigPath = panel.urls.map(\.path).joined(separator: ":")
        }
    }
    #endif
}
