import CrowsnestKit
import SwiftUI

/// Bottom dock with editor and terminal tabs, like Lens' dock panel.
struct EditorDock: View {
    @Environment(ClusterModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            switch model.activeDockItem {
            case .editor(let tab):
                EditorTabView(tab: tab)
                    .id(tab.id)
            case .terminal(let session):
                TerminalTabView(session: session)
                    .id(session.id)
            case nil:
                ContentUnavailableView {
                    Label("No editor open", systemImage: "chevron.left.forwardslash.chevron.right")
                } actions: {
                    NewResourceMenu(label: "New Resource")
                }
            }
        }
        .background(.background)
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(model.editorTabs) { tab in
                        EditorTabButton(tab: tab, isActive: tab.id == model.activeDockItem?.id)
                    }
                    ForEach(model.terminals) { session in
                        TerminalTabButton(session: session, isActive: session.id == model.activeDockItem?.id)
                    }
                }
                .padding(.horizontal, 6)
            }
            NewResourceMenu(label: nil)
                .padding(.horizontal, 4)
            Button {
                model.isEditorVisible = false
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .help("Hide dock (⇧⌘E)")
            .padding(.trailing, 8)
        }
        .frame(height: 30)
        .background(.bar)
    }
}

struct EditorTabButton: View {
    @Environment(ClusterModel.self) private var model
    let tab: EditorTab
    let isActive: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: tab.symbol).font(.caption).foregroundStyle(.secondary)
            Text(tab.title).lineLimit(1).font(.callout)
            ZStack {
                if tab.isDirty && !isHovering {
                    Circle().fill(Color.primary.opacity(0.6)).frame(width: 7, height: 7)
                } else {
                    Button {
                        model.closeEditorTab(tab)
                    } label: {
                        Image(systemName: "xmark").font(.caption2.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .opacity(isHovering || isActive ? 1 : 0)
                    .help("Close")
                }
            }
            .frame(width: 14, height: 14)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isActive ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture { model.activeDockTabID = tab.id }
        .onHover { isHovering = $0 }
        .help(tab.title)
    }
}

struct NewResourceMenu: View {
    @Environment(ClusterModel.self) private var model
    var label: String?

    var body: some View {
        Menu {
            Button("Empty Manifest", systemImage: "doc") { model.newResourceTab() }
            Divider()
            ForEach(ResourceTemplate.all) { template in
                Button(template.name, systemImage: template.symbol) { model.newResourceTab(template) }
            }
        } label: {
            if let label {
                Label(label, systemImage: "plus")
            } else {
                Image(systemName: "plus")
            }
        }
        .borderlessMenuStyle()
        .fixedSize()
        .help("New Resource")
        .disabled(model.client == nil)
    }
}

struct EditorTabView: View {
    @Environment(ClusterModel.self) private var model
    @Bindable var tab: EditorTab

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if tab.hasRemoteChanges && tab.isDirty {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("The object was changed on the server. Saving will cause a conflict.")
                    Spacer()
                    Button("Load from Server") { Task { await model.reloadFromServer(tab) } }
                }
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.12))
            }
            YAMLEditorView(text: $tab.text, errorLine: tab.errorLine)
            statusBar
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            if case .edit(_, _, let ns) = tab.mode, let ns {
                Label(ns, systemImage: "square.stack.3d.up").font(.caption).foregroundStyle(.secondary)
            } else if tab.isCreate {
                Label("Default namespace: \(model.namespaceForNewResources)", systemImage: "square.stack.3d.up")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if tab.isBusy { ProgressView().controlSize(.small) }
            if case .edit = tab.mode {
                Button("Reload", systemImage: "arrow.clockwise") { Task { await model.reloadFromServer(tab) } }
                    .help("Load the current state from the server (discards changes)")
            }
            Button("Revert", systemImage: "arrow.uturn.backward") { tab.text = tab.savedText }
                .disabled(!tab.isDirty)
            Button("Validate", systemImage: "checkmark.shield") { Task { await model.save(tab, dryRun: true) } }
                .help("Server-side dry run: validates without changing anything")
                .disabled(tab.isBusy)
            Button(tab.isCreate ? "Apply & Close" : "Save & Close") {
                Task { await model.save(tab, closeAfterwards: true) }
            }
            .disabled(tab.isBusy || (!tab.isCreate && !tab.isDirty))
            Button(tab.isCreate ? "Apply" : "Save") { Task { await model.save(tab) } }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(tab.isBusy || (!tab.isCreate && !tab.isDirty))
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            switch tab.validation {
            case .valid(let count):
                Label(count == 1 ? "Valid YAML" : "Valid YAML · \(count) documents", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .invalid(let message, _):
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            if let message = tab.message {
                Divider().frame(height: 12)
                Label(message.text, systemImage: message.isError ? "exclamationmark.triangle.fill" : "info.circle")
                    .foregroundStyle(message.isError ? Color.red : Color.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }
}
