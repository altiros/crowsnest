import Foundation
import SwiftUI

/// Links to documentation and the public issue tracker (github.com/altiros/crowsnest).
public enum HelpLinks {
    public static let repository = URL(string: "https://github.com/altiros/crowsnest")!
    public static let help = URL(string: "https://github.com/altiros/crowsnest#readme")!
    public static let releases = URL(string: "https://github.com/altiros/crowsnest/releases")!
    public static let discussions = URL(string: "https://github.com/altiros/crowsnest/discussions")!
    public static let website = URL(string: "https://www.altiros.com/crowsnest/")!
    public static let security = URL(string: "https://github.com/altiros/crowsnest/security/advisories/new")!

    /// "0.1.0 (1)"
    public static var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info["CFBundleVersion"] as? String
        return build.map { "\(version) (\($0))" } ?? version
    }

    public static var platform: String {
        #if os(macOS)
        "macOS"
        #else
        "iPadOS"
        #endif
    }

    public static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(platform) \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// New bug report with version fields pre-filled (GitHub issue forms accept field ids as query items).
    public static var bugReport: URL {
        var components = URLComponents(string: "https://github.com/altiros/crowsnest/issues/new")!
        components.queryItems = [
            URLQueryItem(name: "template", value: "bug_report.yml"),
            URLQueryItem(name: "app-version", value: appVersion),
            URLQueryItem(name: "platform", value: platform),
            URLQueryItem(name: "os-version", value: osVersion),
        ]
        return components.url!
    }

    public static var featureRequest: URL {
        var components = URLComponents(string: "https://github.com/altiros/crowsnest/issues/new")!
        components.queryItems = [
            URLQueryItem(name: "template", value: "feature_request.yml"),
            URLQueryItem(name: "platform", value: platform),
        ]
        return components.url!
    }
}

#if os(macOS)
import AppKit

/// Help menu on macOS (replaces the default "Help isn't available" item).
public struct HelpCommands: Commands {
    public init() {}

    private func openURL(_ url: URL) { NSWorkspace.shared.open(url) }

    public var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Crowsnest Help") { openURL(HelpLinks.help) }
                .keyboardShortcut("?", modifiers: .command)
            Button("Release Notes") { openURL(HelpLinks.releases) }
            Divider()
            Button("Report an Issue…") { openURL(HelpLinks.bugReport) }
            Button("Request a Feature…") { openURL(HelpLinks.featureRequest) }
            Button("Questions & Discussions") { openURL(HelpLinks.discussions) }
            Button("Report a Security Issue…") { openURL(HelpLinks.security) }
            Divider()
            Button("Crowsnest Website") { openURL(HelpLinks.website) }
        }
    }
}
#endif

/// Help & feedback section for the settings sheet (iPad has no Help menu).
struct HelpSection: View {
    var body: some View {
        Section {
            Link(destination: HelpLinks.help) { Label("Help", systemImage: "questionmark.circle") }
            Link(destination: HelpLinks.bugReport) { Label("Report an Issue", systemImage: "ladybug") }
            Link(destination: HelpLinks.featureRequest) { Label("Request a Feature", systemImage: "lightbulb") }
            Link(destination: HelpLinks.discussions) { Label("Questions & Discussions", systemImage: "bubble.left.and.bubble.right") }
            Link(destination: HelpLinks.releases) { Label("Release Notes", systemImage: "list.bullet.rectangle") }
        } header: {
            Text("Help & Feedback")
        } footer: {
            Text("Crowsnest \(HelpLinks.appVersion) · Issues are public – never post kubeconfigs, tokens or secrets.")
        }
    }
}
