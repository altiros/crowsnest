import CrowsnestKit
import Foundation
import Observation

/// One tab in the editor dock: either editing an existing object or creating new resources.
@MainActor @Observable
public final class EditorTab: Identifiable {
    public enum Mode: Equatable {
        case create
        case edit(kind: ResourceKind, name: String, namespace: String?)
    }

    public enum Validation: Equatable {
        case valid(documents: Int)
        case invalid(message: String, line: Int?)
    }

    public struct Message: Equatable {
        public var text: String
        public var isError: Bool
    }

    public let id = UUID()
    public let mode: Mode
    public var title: String
    public var symbol: String
    public var text: String { didSet { if text != oldValue { validate() } } }
    public private(set) var savedText: String
    public private(set) var validation: Validation = .valid(documents: 0)
    public var baseResourceVersion: String?
    public var remoteResourceVersion: String?
    public var message: Message?
    public var isBusy = false

    init(mode: Mode, title: String, symbol: String, text: String, resourceVersion: String? = nil) {
        self.mode = mode
        self.title = title
        self.symbol = symbol
        self.text = text
        self.savedText = text
        self.baseResourceVersion = resourceVersion
        self.remoteResourceVersion = resourceVersion
        validate()
    }

    public var isDirty: Bool { text != savedText }
    public var isCreate: Bool { mode == .create }

    /// The server has a newer version than the one being edited.
    public var hasRemoteChanges: Bool {
        guard let base = baseResourceVersion, let remote = remoteResourceVersion else { return false }
        return base != remote
    }

    public var errorLine: Int? {
        if case .invalid(_, let line) = validation { return line }
        return nil
    }

    func validate() {
        do {
            let docs = try JSONValue.documents(yaml: text)
            if let issue = ManifestIssue.check(docs).first {
                validation = .invalid(message: issue.localizedDescription, line: nil)
            } else if case .edit = mode, docs.count != 1 {
                validation = .invalid(message: "Editing allows exactly one document", line: nil)
            } else {
                validation = .valid(documents: docs.count)
            }
        } catch {
            validation = .invalid(message: error.localizedDescription, line: error.line)
        }
    }

    /// Replaces the content with a fresh server state.
    func load(object: KubeObject) {
        let yaml = (try? object.cleanedForDisplay.yamlString()) ?? ""
        savedText = yaml
        text = yaml
        baseResourceVersion = object.resourceVersion
        remoteResourceVersion = object.resourceVersion
    }

    func markSaved() { savedText = text }
}
