import CrowsnestKit
import Foundation

extension ClusterModel {
    public enum DockItem {
        case editor(EditorTab)
        case terminal(TerminalSession)

        var id: UUID {
            switch self {
            case .editor(let tab): tab.id
            case .terminal(let session): session.id
            }
        }
    }

    /// The tab shown in the dock: the selected one, else the most recent.
    public var activeDockItem: DockItem? {
        if let id = activeDockTabID {
            if let tab = editorTabs.first(where: { $0.id == id }) { return .editor(tab) }
            if let session = terminals.first(where: { $0.id == id }) { return .terminal(session) }
        }
        if let tab = editorTabs.last { return .editor(tab) }
        return terminals.last.map { .terminal($0) }
    }

    /// Namespace for new resources without `metadata.namespace`.
    var namespaceForNewResources: String {
        namespace ?? contextDefaultNamespace ?? "default"
    }

    /// Opens (or focuses) an edit tab for an object, loading its latest state.
    public func openEditor(for object: KubeObject) {
        guard let kind = kind(for: object) else { return }
        isEditorVisible = true
        if let existing = editorTabs.first(where: {
            if case .edit(let k, let n, let ns) = $0.mode { return k == kind && n == object.name && ns == object.namespace }
            return false
        }) {
            activeDockTabID = existing.id
            return
        }
        let tab = EditorTab(mode: .edit(kind: kind, name: object.name, namespace: object.namespace),
                            title: "\(kind.kind)/\(object.name)", symbol: kind.symbol,
                            text: (try? object.cleanedForDisplay.yamlString()) ?? "",
                            resourceVersion: object.resourceVersion)
        editorTabs.append(tab)
        activeDockTabID = tab.id
        Task { await reloadFromServer(tab, onlyIfClean: true) }
    }

    public func newResourceTab(_ template: ResourceTemplate = .empty) {
        let tab = EditorTab(mode: .create,
                            title: template.name == ResourceTemplate.empty.name ? "New resource" : "New: \(template.name)",
                            symbol: "plus.square", text: template.render(namespace: namespaceForNewResources))
        editorTabs.append(tab)
        activeDockTabID = tab.id
        isEditorVisible = true
    }

    public func closeEditorTab(_ tab: EditorTab, force: Bool = false) {
        if tab.isDirty && !force {
            tabPendingClose = tab
            return
        }
        guard let index = editorTabs.firstIndex(where: { $0.id == tab.id }) else { return }
        editorTabs.remove(at: index)
        if activeDockTabID == tab.id {
            activeDockTabID = editorTabs.indices.contains(index) ? editorTabs[index].id : (editorTabs.last?.id ?? terminals.last?.id)
        }
        if editorTabs.isEmpty && terminals.isEmpty { isEditorVisible = false }
    }

    /// Loads the current server state into an edit tab.
    public func reloadFromServer(_ tab: EditorTab, onlyIfClean: Bool = false) async {
        guard let client, case .edit(let kind, let name, let ns) = tab.mode else { return }
        do {
            let object = try await client.get(kind, name: name, namespace: ns)
            if onlyIfClean && tab.isDirty {
                tab.remoteResourceVersion = object.resourceVersion
            } else {
                tab.load(object: object)
                tab.message = nil
            }
        } catch {
            tab.message = .init(text: error.localizedDescription, isError: true)
        }
    }

    /// Saves (edit) or applies (create) the tab. With `dryRun` the API server only validates.
    public func save(_ tab: EditorTab, dryRun: Bool = false, closeAfterwards: Bool = false) async {
        guard let client, !tab.isBusy else { return }
        if case .invalid(let message, _) = tab.validation {
            tab.message = .init(text: message, isError: true)
            return
        }
        tab.isBusy = true
        defer { tab.isBusy = false }
        do {
            let docs = try JSONValue.documents(yaml: tab.text)
            switch tab.mode {
            case .edit(let kind, _, _):
                let result = try await client.replace(kind, object: docs[0], dryRun: dryRun)
                if dryRun {
                    tab.message = .init(text: "Check passed – the server would accept the change", isError: false)
                } else {
                    tab.load(object: result)
                    tab.message = .init(text: "Saved (resourceVersion \(result.resourceVersion ?? "?"))", isError: false)
                    toast = "\(result.name) saved"
                }
            case .create:
                var summary: [String] = []
                for (index, doc) in docs.enumerated() {
                    do {
                        let r = try await client.apply(doc, defaultNamespace: namespaceForNewResources, dryRun: dryRun)
                        summary.append("\(r.kind.kind)/\(r.object.name) \(r.created ? "created" : "updated")")
                    } catch {
                        let prefix = docs.count > 1 ? "Document \(index + 1): " : ""
                        throw KubeError.invalidInput(prefix + error.localizedDescription + (summary.isEmpty ? "" : " – applied before: \(summary.joined(separator: ", "))"))
                    }
                }
                if dryRun {
                    tab.message = .init(text: "Check passed: \(summary.joined(separator: ", "))", isError: false)
                } else {
                    tab.markSaved()
                    tab.message = .init(text: "Applied: \(summary.joined(separator: ", "))", isError: false)
                    toast = docs.count == 1 ? "Resource applied" : "\(docs.count) resources applied"
                }
            }
            if !dryRun {
                await reload()
                if closeAfterwards { closeEditorTab(tab, force: true) }
            }
        } catch let error as KubeError where error.httpStatus == 409 {
            tab.message = .init(text: "Conflict: the object was changed in the meantime. Reload and make your changes again.", isError: true)
        } catch {
            tab.message = .init(text: error.localizedDescription, isError: true)
        }
    }

    /// Called after list reloads: track server-side changes of objects open in the editor.
    func syncEditorTabs(with kind: ResourceKind, objects: [KubeObject]) {
        for tab in editorTabs {
            guard case .edit(let k, let name, let ns) = tab.mode, k == kind,
                  let object = objects.first(where: { $0.name == name && $0.namespace == ns }) else { continue }
            if object.resourceVersion != tab.remoteResourceVersion {
                if tab.isDirty {
                    tab.remoteResourceVersion = object.resourceVersion
                } else if !tab.isBusy {
                    tab.load(object: object)
                }
            }
        }
    }
}
