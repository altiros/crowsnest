import CrowsnestKit
import SwiftUI

/// Extension point for features that are not part of the open core (e.g. Crowsnest Pro).
///
/// The core never imports an extension. The app target registers extensions at launch
/// (`Extensions.register(…)`), and the UI asks the registry for sidebar entries and settings.
@MainActor
public protocol CrowsnestExtension: AnyObject {
    /// Stable identifier, e.g. "pro".
    var id: String { get }
    /// Title of the sidebar section the extension's items appear in (e.g. "Pro").
    var sidebarSection: String { get }
    /// Pages shown in the sidebar.
    var pages: [ExtensionPage] { get }
    /// Optional section for the settings window/sheet (e.g. license).
    func settingsSection() -> AnyView?
}

/// A sidebar page provided by an extension.
public struct ExtensionPage: Identifiable {
    /// Unique within the app, e.g. "pro.deprecated-apis".
    public let id: String
    public let title: String
    public let symbol: String
    /// Builds the page; gets the window's cluster model.
    public let content: @MainActor (ClusterModel) -> AnyView

    public init(id: String, title: String, symbol: String, content: @escaping @MainActor (ClusterModel) -> AnyView) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.content = content
    }
}

/// Registry of extensions for this app process.
@MainActor
public enum Extensions {
    public private(set) static var registered: [any CrowsnestExtension] = []

    public static func register(_ ext: any CrowsnestExtension) {
        guard !registered.contains(where: { $0.id == ext.id }) else { return }
        registered.append(ext)
    }

    static func page(id: String) -> ExtensionPage? {
        registered.lazy.flatMap(\.pages).first { $0.id == id }
    }

    /// True if any extension is installed (the official build); false for the open-source build.
    public static var hasExtensions: Bool { !registered.isEmpty }
}

/// Sidebar sections contributed by extensions.
struct ExtensionSidebarSections: View {
    var body: some View {
        ForEach(Extensions.registered, id: \.id) { ext in
            Section(ext.sidebarSection) {
                ForEach(ext.pages) { page in
                    Label(page.title, systemImage: page.symbol)
                        .tag(SidebarItem.extensionPage(page.id))
                }
            }
        }
    }
}

/// Settings sections contributed by extensions.
struct ExtensionSettingsSections: View {
    var body: some View {
        ForEach(Extensions.registered, id: \.id) { ext in
            if let section = ext.settingsSection() { section }
        }
    }
}
