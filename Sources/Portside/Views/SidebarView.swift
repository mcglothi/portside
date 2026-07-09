import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var sessions: SessionManager
    @State private var filter = ""
    @State private var editingEntry: SessionEntry?
    @State private var editingMacro: Macro?
    @State private var showingImporter = false
    @State private var importMessage: String?
    // Folder create/rename prompts. `newFolderParent` non-nil ("" = top level)
    // means the New Folder alert is showing; `renamingFolder` drives Rename.
    @State private var newFolderParent: String?
    @State private var newFolderName = ""
    @State private var renamingFolder: String?
    @State private var renameFolderName = ""
    @State private var selectedEntryID: UUID?

    private var filteredEntries: [SessionEntry] {
        guard !filter.isEmpty else { return store.entries }
        return store.entries.filter {
            $0.name.localizedCaseInsensitiveContains(filter)
                || $0.subtitle.localizedCaseInsensitiveContains(filter)
                || $0.folder.localizedCaseInsensitiveContains(filter)
        }
    }

    var body: some View {
        let tree = FolderTree.build(entries: filteredEntries, explicitFolders: store.explicitFolders)
        List(selection: $selectedEntryID) {
            Section("Sessions") {
                ForEach(tree.folders) { node in
                    FolderGroupView(
                        node: node,
                        connect: connect,
                        edit: { editingEntry = $0 },
                        newSubfolder: { newFolderName = ""; newFolderParent = $0 },
                        rename: { renameFolderName = $1; renamingFolder = $0 }
                    )
                }
                ForEach(tree.root) { entry in
                    SessionRow(entry: entry, connect: connect, edit: { editingEntry = $0 })
                }
            }
            Section("Macros") {
                ForEach(store.macros) { macro in
                    MacroRow(macro: macro, run: { sessions.run($0) }, edit: { editingMacro = $0 })
                }
                Button {
                    editingMacro = Macro(name: "", text: "")
                } label: {
                    Label("New Macro…", systemImage: "plus")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .searchable(text: $filter, placement: .sidebar, prompt: "Filter sessions")
        .navigationTitle("Portside")
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("New Session…") {
                        editingEntry = SessionEntry(name: "")
                    }
                    Button("New Folder…") {
                        newFolderName = ""
                        newFolderParent = ""
                    }
                    Button("New Macro…") {
                        editingMacro = Macro(name: "", text: "")
                    }
                    Divider()
                    Button("Import MobaXterm File…") {
                        showingImporter = true
                    }
                    Button("Re-import ~/.ssh/config") {
                        let added = store.mergeSSHConfig()
                        importMessage = added == 0
                            ? "No new hosts found in ~/.ssh/config."
                            : "Added \(added) new host\(added == 1 ? "" : "s") from ~/.ssh/config."
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
            ToolbarItem {
                Button {
                    sessions.openLocalShell()
                } label: {
                    Label("New Local Shell", systemImage: "terminal")
                }
                .help("New local shell (⌘T)")
            }
        }
        .sheet(item: $editingEntry) { entry in
            SessionEditorView(entry: entry, folders: store.folders) { result in
                switch result {
                case .save(let updated): store.upsert(updated)
                case .delete: store.delete(entry)
                }
            }
        }
        .sheet(item: $editingMacro) { macro in
            MacroEditorView(macro: macro) { result in
                switch result {
                case .save(let updated): store.upsert(updated)
                case .delete: store.delete(macro)
                }
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .alert(
            "Import",
            isPresented: Binding(
                get: { importMessage != nil },
                set: { if !$0 { importMessage = nil } }
            )
        ) {
            Button("OK") {}
        } message: {
            Text(importMessage ?? "")
        }
        .alert(
            newFolderParent.map { $0.isEmpty ? "New Folder" : "New Subfolder in \($0)" } ?? "New Folder",
            isPresented: Binding(
                get: { newFolderParent != nil },
                set: { if !$0 { newFolderParent = nil } }
            )
        ) {
            TextField("Name", text: $newFolderName)
            Button("Create") {
                let parent = newFolderParent ?? ""
                let name = newFolderName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    store.createFolder(parent.isEmpty ? name : "\(parent)/\(name)")
                }
                newFolderName = ""
                newFolderParent = nil
            }
            Button("Cancel", role: .cancel) { newFolderName = ""; newFolderParent = nil }
        }
        .alert(
            "Rename Folder",
            isPresented: Binding(
                get: { renamingFolder != nil },
                set: { if !$0 { renamingFolder = nil } }
            )
        ) {
            TextField("Name", text: $renameFolderName)
            Button("Rename") {
                if let path = renamingFolder {
                    store.renameFolder(path, to: renameFolderName)
                }
                renamingFolder = nil
            }
            Button("Cancel", role: .cancel) { renamingFolder = nil }
        }
    }

    private func connect(_ entry: SessionEntry) {
        sessions.connect(to: store.resolved(entry))
    }

    private func handleImport(_ result: Swift.Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importMessage = "Import failed: \(error.localizedDescription)"
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let parsed = try MobaXtermImporter.importFile(at: url)
                let added = store.addImported(entries: parsed.entries, macros: parsed.macros)
                var parts = ["Imported \(added.sessions) session\(added.sessions == 1 ? "" : "s")"]
                if added.macros > 0 { parts.append("\(added.macros) macro\(added.macros == 1 ? "" : "s")") }
                if parsed.skippedNonSSH > 0 { parts.append("skipped \(parsed.skippedNonSSH) non-SSH entries") }
                importMessage = parts.joined(separator: ", ") + "."
            } catch {
                importMessage = "Import failed: \(error.localizedDescription)"
            }
        }
    }
}

struct FolderGroupView: View {
    @EnvironmentObject var store: SessionStore
    let node: FolderNode
    let connect: (SessionEntry) -> Void
    let edit: (SessionEntry) -> Void
    let newSubfolder: (String) -> Void
    let rename: (_ path: String, _ currentName: String) -> Void

    var body: some View {
        DisclosureGroup {
            ForEach(node.subfolders) { child in
                FolderGroupView(node: child, connect: connect, edit: edit,
                                newSubfolder: newSubfolder, rename: rename)
            }
            ForEach(node.entries) { entry in
                SessionRow(entry: entry, connect: connect, edit: edit)
            }
        } label: {
            Label(node.name, systemImage: "folder")
                .contentShape(Rectangle())
                .dropDestination(for: String.self) { ids, _ in
                    move(ids: ids, into: node.path)
                    return true
                }
                .contextMenu {
                    Button("New Subfolder…") { newSubfolder(node.path) }
                    Button("Rename…") { rename(node.path, node.name) }
                    Divider()
                    Button("Delete Folder", role: .destructive) { store.deleteFolder(node.path) }
                }
        }
    }

    private func move(ids: [String], into folder: String) {
        for id in ids {
            if let uuid = UUID(uuidString: id) {
                store.move(entryID: uuid, toFolder: folder)
            }
        }
    }
}

struct SessionRow: View {
    @EnvironmentObject var store: SessionStore
    let entry: SessionEntry
    let connect: (SessionEntry) -> Void
    let edit: (SessionEntry) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "server.rack")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                Text(entry.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if entry.isProtected {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Protected host")
            }
            EnvironmentBadge(environment: entry.environment)
        }
        .contentShape(Rectangle())
        .tag(entry.id)
        .onTapGesture(count: 2) { connect(entry) }
        .help("Double-click to connect")
        // `.onDrag` (NSItemProvider) is the List-compatible drag source. The row
        // is a drag SOURCE only — drop targets live on folders, never on the same
        // row, which is what previously locked up List selection after a drag.
        .onDrag { NSItemProvider(object: entry.id.uuidString as NSString) }
        .contextMenu {
            Button("Connect") { connect(entry) }
            Button("Edit…") { edit(entry) }
            Divider()
            Button("Delete", role: .destructive) { store.delete(entry) }
        }
    }
}

struct MacroRow: View {
    @EnvironmentObject var store: SessionStore
    let macro: Macro
    let run: (Macro) -> Void
    let edit: (Macro) -> Void

    var body: some View {
        Button {
            run(macro)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "play.circle")
                    .foregroundStyle(.secondary)
                Text(macro.name)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(macro.text)
        .contextMenu {
            Button("Run") { run(macro) }
            Button("Edit…") { edit(macro) }
            Divider()
            Button("Delete", role: .destructive) { store.delete(macro) }
        }
    }
}
