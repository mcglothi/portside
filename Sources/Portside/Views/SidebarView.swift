import SwiftUI
import UniformTypeIdentifiers

/// The sidebar is split into distinct sections so hosts, macros, and tools
/// aren't one long list — and so more tools can be added over time.
enum SidebarSection: String, CaseIterable, Identifiable {
    case hosts, macros, tools
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hosts: return "Hosts"
        case .macros: return "Macros"
        case .tools: return "Tools"
        }
    }
    var icon: String {
        switch self {
        case .hosts: return "server.rack"
        case .macros: return "bolt"
        case .tools: return "wrench.and.screwdriver"
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var sessions: SessionManager
    @State private var section: SidebarSection = .hosts
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
        VStack(spacing: 0) {
            Picker("Section", selection: $section) {
                ForEach(SidebarSection.allCases) { s in
                    Label(s.title, systemImage: s.icon).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider()

            switch section {
            case .hosts: hostsList
            case .macros: macrosList
            case .tools: ToolsList()
            }
        }
        .navigationTitle("Portside")
        .toolbar { toolbarContent }
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

    // MARK: - Sections

    private var hostsList: some View {
        let tree = FolderTree.build(entries: filteredEntries, explicitFolders: store.explicitFolders)
        // Selection is managed manually (not List(selection:)): native list
        // selection competes with the row's own click/drag handling, which made
        // clicks on the row content unreliable. A plain List + our own highlight
        // puts the click handler where the click actually lands.
        return List {
            ForEach(tree.folders) { node in
                FolderGroupView(
                    node: node,
                    selection: $selectedEntryID,
                    connect: connect,
                    edit: { editingEntry = $0 },
                    newSubfolder: { newFolderName = ""; newFolderParent = $0 },
                    rename: { renameFolderName = $1; renamingFolder = $0 }
                )
            }
            ForEach(tree.root) { entry in
                SessionRow(entry: entry, selection: $selectedEntryID,
                           connect: connect, edit: { editingEntry = $0 })
            }
        }
        .searchable(text: $filter, placement: .sidebar, prompt: "Filter hosts")
        .overlay {
            if store.entries.isEmpty {
                ContentUnavailableView("No hosts yet",
                    systemImage: "server.rack",
                    description: Text("Add a session or import from ~/.ssh/config."))
            }
        }
    }

    private var macrosList: some View {
        List {
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
        .overlay {
            if store.macros.isEmpty {
                ContentUnavailableView("No macros yet",
                    systemImage: "bolt",
                    description: Text("Macros send saved text to the active or broadcast terminals."))
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem {
            Menu {
                switch section {
                case .hosts:
                    Button("New Session…") { editingEntry = SessionEntry(name: "") }
                    Button("New Folder…") { newFolderName = ""; newFolderParent = "" }
                    Divider()
                    Button("Import MobaXterm File…") { showingImporter = true }
                    Button("Re-import ~/.ssh/config") {
                        let added = store.mergeSSHConfig()
                        importMessage = added == 0
                            ? "No new hosts found in ~/.ssh/config."
                            : "Added \(added) new host\(added == 1 ? "" : "s") from ~/.ssh/config."
                    }
                case .macros:
                    Button("New Macro…") { editingMacro = Macro(name: "", text: "") }
                case .tools:
                    Button("New Local Shell") { sessions.openLocalShell() }
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
    @Binding var selection: UUID?
    let connect: (SessionEntry) -> Void
    let edit: (SessionEntry) -> Void
    let newSubfolder: (String) -> Void
    let rename: (_ path: String, _ currentName: String) -> Void

    var body: some View {
        DisclosureGroup {
            ForEach(node.subfolders) { child in
                FolderGroupView(node: child, selection: $selection, connect: connect, edit: edit,
                                newSubfolder: newSubfolder, rename: rename)
            }
            ForEach(node.entries) { entry in
                SessionRow(entry: entry, selection: $selection, connect: connect, edit: edit)
            }
        } label: {
            Label(node.name, systemImage: "folder")
                .contextMenu {
                    Button("New Subfolder…") { newSubfolder(node.path) }
                    Button("Rename…") { rename(node.path, node.name) }
                    Divider()
                    Button("Delete Folder", role: .destructive) { store.deleteFolder(node.path) }
                }
        }
    }
}

struct SessionRow: View {
    @EnvironmentObject var store: SessionStore
    let entry: SessionEntry
    @Binding var selection: UUID?
    let connect: (SessionEntry) -> Void
    let edit: (SessionEntry) -> Void

    private var isSelected: Bool { selection == entry.id }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "server.rack")
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                Text(entry.subtitle)
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
            }
            Spacer(minLength: 4)
            if entry.isProtected {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
                    .help("Protected host")
            }
            EnvironmentBadge(environment: entry.environment)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color(nsColor: .selectedContentBackgroundColor) : .clear)
        )
        // Manual selection: single click selects immediately (no native List
        // selection to compete for the click); double-click connects.
        .onTapGesture { selection = entry.id }
        .simultaneousGesture(TapGesture(count: 2).onEnded { connect(entry) })
        .help("Click to select, double-click to connect")
        .contextMenu {
            Button("Connect") { connect(entry) }
            Button("Edit…") { edit(entry) }
            if !moveTargets.isEmpty {
                Menu("Move to") {
                    ForEach(moveTargets, id: \.self) { target in
                        Button(target.isEmpty ? "Top Level" : target) {
                            store.move(entryID: entry.id, toFolder: target)
                        }
                    }
                }
            }
            Divider()
            Button("Delete", role: .destructive) { store.delete(entry) }
        }
    }

    /// Folders the session can move to, plus "Top Level" when it's in a folder.
    private var moveTargets: [String] {
        var targets = store.folders.filter { $0 != entry.folder }
        if !entry.folder.isEmpty { targets.insert("", at: 0) }
        return targets
    }
}

/// Home for standalone tools. Local shell works today; the rest are the
/// roadmap items (port forwarding, quick connect) surfaced as disabled rows
/// so the section shows where they'll live.
struct ToolsList: View {
    @EnvironmentObject var sessions: SessionManager

    var body: some View {
        List {
            Section("Terminal") {
                Button {
                    sessions.openLocalShell()
                } label: {
                    Label("New Local Shell", systemImage: "terminal")
                }
                .buttonStyle(.plain)
            }
            Section("Coming soon") {
                Label("Port Forwarding", systemImage: "arrow.left.arrow.right")
                    .foregroundStyle(.tertiary)
                Label("Quick Connect", systemImage: "bolt.horizontal")
                    .foregroundStyle(.tertiary)
                Label("Split Layouts", systemImage: "rectangle.split.2x1")
                    .foregroundStyle(.tertiary)
            }
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
