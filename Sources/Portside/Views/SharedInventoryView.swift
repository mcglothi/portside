import AppKit
import SwiftUI

/// Subscribing to team inventories published over git, and seeing where each
/// one stands. File ▸ Shared Inventory…, or a source's own context menu.
struct SharedInventoryView: View {
    @EnvironmentObject var store: SessionStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var remote = ""
    @State private var ref = "main"
    @State private var path = "portside.json"
    @State private var addError: String?
    @State private var removing: InventorySource?

    private var draft: InventorySource {
        InventorySource(name: name, remote: remote, ref: ref, path: path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Shared Inventory").font(.headline)
                Spacer()
                if !store.inventorySources.isEmpty {
                    Button("Pull All") { Task { await store.refreshInventorySources() } }
                        .disabled(store.inventorySources.contains { store.sharedState[$0.id]?.isSyncing == true })
                }
            }
            Text("Hosts a team publishes to a git repository, shown read-only beside your own. "
                 + "Portside clones and fast-forwards with your own git and never pushes. "
                 + "Publish one with File \u{25B8} Export Sessions\u{2026} and commit the file.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if store.inventorySources.isEmpty {
                Text("No shared inventories yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(store.inventorySources) { source in
                            sourceRow(source)
                        }
                    }
                }
                .frame(maxHeight: 260)
            }

            Divider()
            addForm

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 560)
        .alert("Remove \u{201C}\(removing?.name ?? "")\u{201D}?", isPresented: .constant(removing != nil)) {
            Button("Remove", role: .destructive) {
                if let removing { store.removeInventorySource(id: removing.id) }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("Its hosts leave the sidebar, along with your own settings on them — favourites, "
                 + "credential profiles and saved passwords. The repository itself isn't touched.")
        }
    }

    private func sourceRow(_ source: InventorySource) -> some View {
        let state = store.sharedState[source.id] ?? SharedInventoryState()
        let count = store.sharedEntries(inSource: source.id).count
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "person.2.fill").foregroundStyle(.secondary)
                Text(source.name).font(.body.weight(.semibold))
                Spacer()
                if state.isSyncing {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Pull") { Task { await store.refreshInventorySource(id: source.id) } }
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([store.cloneDirectory(for: source.id)])
                } label: { Image(systemName: "folder") }
                    .help("Show the local clone in Finder")
                    .disabled(!FileManager.default.fileExists(atPath: store.cloneDirectory(for: source.id).path))
                Button(role: .destructive) { removing = source } label: { Image(systemName: "trash") }
                    .help("Unsubscribe")
            }
            Text("\(source.remote)  \u{00B7}  \(source.ref)  \u{00B7}  \(source.path)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Text(summary(state, count: count))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = state.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }

    private func summary(_ state: SharedInventoryState, count: Int) -> String {
        var parts = ["\(count) host\(count == 1 ? "" : "s")"]
        if state.skipped > 0 {
            parts.append("\(state.skipped) skipped (not SSH hosts, or unsafe values)")
        }
        if let commit = state.commit { parts.append("at \(commit)") }
        if let synced = state.lastSynced {
            parts.append("pulled \(RelativeTime.phrase(for: synced))")
        } else if state.error == nil && !state.isSyncing {
            parts.append("not pulled this session")
        }
        return parts.joined(separator: "  \u{00B7}  ")
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add a source").font(.subheadline.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text("Name").gridColumnAlignment(.trailing)
                    TextField("", text: $name, prompt: Text("Platform Team"))
                }
                GridRow {
                    Text("Git URL")
                    TextField("", text: $remote, prompt: Text("git@git.example.com:team/inventory.git"))
                }
                GridRow {
                    Text("Branch")
                    HStack {
                        TextField("", text: $ref).frame(width: 120)
                        Text("Manifest")
                        TextField("", text: $path)
                    }
                }
            }
            // Said where the decision is made, not buried in docs: no secrets
            // travel, but a host list is still a very good map of an estate.
            Label("A manifest holds no secrets, but it is a map of your infrastructure. "
                  + "Keep the repository private, and subscribe only to sources you trust: "
                  + "anyone who can push to it decides which hosts appear here.",
                  systemImage: "exclamationmark.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let addError {
                Text(addError).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Add and Pull") { add() }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                              || remote.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func add() {
        let source = draft
        if let problem = store.addInventorySource(source) {
            addError = problem
            return
        }
        addError = nil
        name = ""
        remote = ""
        ref = "main"
        path = "portside.json"
        Task { await store.refreshInventorySource(id: source.id) }
    }
}
