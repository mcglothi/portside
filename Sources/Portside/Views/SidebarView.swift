import AppKit
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
    @EnvironmentObject var tunnels: TunnelManager
    @EnvironmentObject var library: LibraryCommands
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
    @State private var renamingGroup: SessionGroup?
    @State private var renameGroupName = ""
    @State private var groupToDelete: SessionGroup?
    @State private var savingGroup = false
    @State private var newGroupName = ""
    @State private var newGroupFolder = ""
    /// Set when a launch couldn't open every member, so the user is told
    /// which hosts are gone rather than silently getting a smaller grid.
    @State private var groupLaunchNotice: String?
    @State private var selection: Set<UUID> = []
    @State private var showingKeyDistribution = false
    /// Hosts the key sheet opens with already ticked — a right-clicked host,
    /// a multi-selection, or every host in a right-clicked folder. Empty when
    /// the sheet is opened from the menu bar, which falls back to whatever the
    /// sidebar selection happens to be.
    @State private var keyDistributionPreselection: Set<UUID> = []
    /// Set only when the trip started from a credential profile.
    @State private var keyDistributionKeyPath: String?
    @State private var showingKeyRotation = false

    /// Held as a constant rather than concatenated inline: a chain of `+` on
    /// string literals inside a `Text` is surprisingly expensive to type-check,
    /// and this body is close enough to the limit that it was the difference
    /// between compiling and not.
    private static let externalChangeMessage = """
        Something else wrote to your session library since Portside read it — another \
        copy of Portside, or a sync client bringing down changes made elsewhere. \
        Saving now would discard them.

        Reload takes the version on disk. Portside has not saved anything in the meantime.
        """

    @State private var showingLogSearch = false
    @State private var showingPortForwarding = false
    @State private var showingCoverage = false
    @State private var showingHistory = false
    /// Bumped when the filter field's first arrow-key press should hand
    /// keyboard focus to the host list.
    @State private var sidebarFocusRequest = 0
    @State private var expandAllRequest = 0
    @State private var collapseAllRequest = 0

    private var loadFailureMessage: String {
        var text = "Portside kept your original file and has not changed it. "
        text += "Nothing you do in this session will be saved until it's resolved, "
        text += "so your existing hosts can't be overwritten."
        if let path = store.quarantinedLibraryPath {
            text += "\n\nA copy is at \(path)"
        }
        return text
    }

    private var filteredEntries: [SessionEntry] {
        guard !filter.isEmpty else { return store.entries }
        return store.entries.filter {
            $0.name.localizedCaseInsensitiveContains(filter)
                || $0.subtitle.localizedCaseInsensitiveContains(filter)
                || $0.folder.localizedCaseInsensitiveContains(filter)
        }
    }

    /// Groups match the host filter on their own name, so filtering for
    /// "splunk" finds the group as well as the boxes in it.
    private var filteredGroups: [SessionGroup] {
        guard !filter.isEmpty else { return store.groups }
        return store.groups.filter {
            $0.name.localizedCaseInsensitiveContains(filter)
                || $0.folder.localizedCaseInsensitiveContains(filter)
        }
    }

    /// The sidebar's actual content, split out from `body`.
    ///
    /// `body` is a single expression carrying every sheet, alert and command
    /// route this view owns, and it sits right at the edge of what the
    /// type-checker will solve — close enough that adding one `.sheet` failed
    /// to compile with the error pointing at this `Picker`, two hundred lines
    /// from the change. A computed property is type-checked on its own, which
    /// buys the room back honestly instead of by deleting something.
    private var content: some View {
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
            case .tools: ToolsList(searchLogs: { showingLogSearch = true },
                                   portForwarding: { showingPortForwarding = true },
                                   coverage: { showingCoverage = true },
                                   history: { showingHistory = true })
            }
        }
    }

    var body: some View {
        content
        .navigationTitle("Portside")
        .toolbar { toolbarContent }
        // Single implementation of each library command; the toolbar menus
        // and the menu bar both get here by bumping a token. Routed through a
        // ViewModifier because inlining nine onChange handlers alongside the
        // sheets and alerts pushed this body past what the type-checker will
        // solve in reasonable time.
        .modifier(LibraryCommandRouter(
            library: library,
            onNewSession: {
                section = .hosts
                var entry = SessionEntry(name: "")
                entry.savePassword = store.defaults.defaultSavePassword ?? false
                editingEntry = entry
            },
            onNewFolder: {
                section = .hosts
                newFolderName = ""
                newFolderParent = ""
            },
            onImport: { showingImporter = true },
            onExportSessions: { exportSessions() },
            onExportMacros: { exportMacros() },
            onReimportSSHConfig: {
                let added = store.mergeSSHConfig()
                importMessage = added == 0
                    ? "No new hosts found in ~/.ssh/config."
                    : "Added \(added) new host\(added == 1 ? "" : "s") from ~/.ssh/config."
            },
            onExpandAll: { section = .hosts; expandAllRequest += 1 },
            onCollapseAll: { section = .hosts; collapseAllRequest += 1 },
            onShowCoverage: { showingCoverage = true },
            onShowHistory: { showingHistory = true },
            onSaveTabAsGroup: {
                let tab = sessions.selectedTab
                // A name you chose, or the group's own, or a placeholder worth
                // typing over. It used to fall back to the active pane's title,
                // which for a local shell is the whole prompt —
                // "mcglothi@Newton:~/code/portside" — a name nobody wants and
                // an ugly thing to hand someone with the field pre-selected.
                newGroupName = tab?.customTitle
                    ?? tab?.groupID.flatMap { store.group(id: $0)?.name }
                    ?? "New Group"
                // Re-saving a group offers its current folder, so the common
                // case of overwriting one doesn't quietly move it to the root.
                newGroupFolder = tab?.groupID.flatMap { store.group(id: $0)?.folder } ?? ""
                savingGroup = true
            },
            onCopyKeyToHosts: {
                keyDistributionPreselection = selection
                keyDistributionKeyPath = nil
                showingKeyDistribution = true
            },
            onRotateKey: {
                // Same starting point as a push: the sidebar selection is a
                // proposal, and the sheet's own confirmation names every host.
                keyDistributionPreselection = selection
                showingKeyRotation = true
            }
        ))
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
        .modifier(LibrarySheets(
            coverage: $showingCoverage,
            history: $showingHistory,
            logSearch: $showingLogSearch,
            portForwarding: $showingPortForwarding,
            keyDistribution: $showingKeyDistribution,
            keyRotation: $showingKeyRotation,
            keyPreselection: keyDistributionPreselection,
            keyPath: keyDistributionKeyPath,
            store: store, library: library, tunnels: tunnels
        ))
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        // A quarantined library means the app is running empty and refusing to
        // write. Silently sitting there would look like data loss and invite
        // the user to recreate everything on top of a recoverable file.
        .alert("Your session library could not be read", isPresented: .constant(store.loadFailure != nil)) {
            if let path = store.quarantinedLibraryPath {
                Button("Reveal Copy in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            }
            Button("Continue Without Saving", role: .cancel) {}
        } message: {
            Text(loadFailureMessage)
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
        .alert("Your library changed outside Portside",
               isPresented: .constant(store.externalChange)) {
            Button("Reload") { store.reloadAfterExternalChange() }
            Button("Keep Mine and Overwrite", role: .destructive) {
                store.overwriteExternalChange()
            }
        } message: {
            Text(Self.externalChangeMessage)
        }
        .modifier(GroupAlerts(
            savingGroup: $savingGroup, newGroupName: $newGroupName,
            newGroupFolder: $newGroupFolder,
            renamingGroup: $renamingGroup, renameGroupName: $renameGroupName,
            groupToDelete: $groupToDelete, launchNotice: $groupLaunchNotice,
            store: store, sessions: sessions))
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
        let tree = FolderTree.build(entries: filteredEntries,
                                    explicitFolders: store.explicitFolders,
                                    groups: filteredGroups)
        // The hosts list is an NSOutlineView (HostOutlineView) so selection and
        // drag are native — SwiftUI's List couldn't do range selection or
        // reliable drag-to-folder. Macros/Tools stay on SwiftUI List.
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                TextField("Filter hosts", text: $filter)
                    .textFieldStyle(.plain)
                    .onKeyPress(.downArrow) {
                        guard !filter.isEmpty else { return .ignored }
                        moveFocusToResults(selectFirst: true)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        guard !filter.isEmpty else { return .ignored }
                        moveFocusToResults(selectFirst: false)
                        return .handled
                    }
                if !filter.isEmpty {
                    Button { filter = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider()

            HostOutlineView(
                tree: tree,
                selection: $selection,
                store: store,
                searching: !filter.isEmpty,
                focusRequest: sidebarFocusRequest,
                expandAllRequest: expandAllRequest,
                collapseAllRequest: collapseAllRequest,
                connect: connect,
                launchGroup: launchGroup,
                renameGroup: { renameGroupName = $0.name; renamingGroup = $0 },
                deleteGroup: { groupToDelete = $0 },
                connectSelected: openSelected,
                edit: { editingEntry = $0 },
                openFolder: openFolder,
                copyKeyToHosts: { ids, keyPath in
                    keyDistributionPreselection = ids
                    keyDistributionKeyPath = keyPath
                    showingKeyDistribution = true
                },
                rotateKeyOnHosts: { ids in
                    keyDistributionPreselection = ids
                    showingKeyRotation = true
                },
                newSubfolder: { newFolderName = ""; newFolderParent = $0 },
                renameFolder: { renameFolderName = $1; renamingFolder = $0 }
            )
            .overlay {
                // Groups count as content. Checking only `entries` drew "No
                // hosts yet" straight over a sidebar with folders and groups
                // visible in it — the list is right there underneath, being
                // told it doesn't exist.
                if store.entries.isEmpty && store.groups.isEmpty {
                    EmptyStateView(
                        icon: "server.rack",
                        title: "No hosts yet",
                        detail: "Add a session, or import the hosts you already have in ~/.ssh/config.",
                        action: EmptyStateView.Action(label: "Import…") { library.requestImport() }
                    )
                }
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
                EmptyStateView(
                    icon: "bolt",
                    title: "No macros yet",
                    detail: "Macros send saved text to the active terminal, or to every broadcast target at once.",
                    action: EmptyStateView.Action(label: "New Macro…") { editingMacro = Macro(name: "", text: "") }
                )
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if section == .hosts {
            ToolbarItem {
                Menu {
                    Button("Open \(selection.count) Selected") { openSelected(multiExec: false) }
                    Button("Open \(selection.count) in MultiExec") { openSelected(multiExec: true) }
                } label: {
                    Label("Open Selected", systemImage: "play.fill")
                }
                .menuIndicator(selection.isEmpty ? .hidden : .visible)
                .disabled(selection.isEmpty)
                .help("Open the selected hosts (⌘-click to select several)")
            }
        }
        // Creation only, so the "+" means what its icon says. Library
        // actions live under the ellipsis beside it, and both surfaces route
        // through LibraryCommands so the menu bar runs the same code.
        ToolbarItem {
            Menu {
                switch section {
                case .hosts:
                    Button("New Session…") { library.requestNewSession() }
                    Button("New Folder…") { library.requestNewFolder() }
                    // Also under Tools ▸ +, but Hosts is where people actually
                    // are, and a local shell was reachable from the menu bar or
                    // the welcome page only — not from the + they were already
                    // clicking. Raised by a colleague of Tim's.
                    Divider()
                    Button("New Local Shell") { sessions.openLocalShell() }
                case .macros:
                    Button("New Macro…") { editingMacro = Macro(name: "", text: "") }
                case .tools:
                    Button("New Local Shell") { sessions.openLocalShell() }
                }
            } label: {
                Label("New", systemImage: "plus")
            }
            .help("Create a session, folder, macro, or local shell")
        }
        if section != .tools {
            ToolbarItem {
                Menu {
                    Button("Import…") { library.requestImport() }
                    if section == .hosts {
                        Button("Export Sessions…") { library.requestExportSessions() }
                            .disabled(store.entries.isEmpty)
                    }
                    Button("Export Macros…") { library.requestExportMacros() }
                        .disabled(store.macros.isEmpty)
                    if section == .hosts {
                        Divider()
                        Button("Re-import ~/.ssh/config") { library.requestReimportSSHConfig() }
                    }
                } label: {
                    Label("Library", systemImage: "ellipsis.circle")
                }
                .help("Import and export your library")
            }
        }
    }

    private func connect(_ entry: SessionEntry) {
        sessions.connect(to: store.resolved(entry))
    }

    /// Opens a saved group, reporting anything that couldn't be opened.
    ///
    /// A member that's been deleted since the group was saved is skipped, not
    /// fatal — but it is said out loud. Silently opening six of eight is how
    /// you run a command believing it reached the whole platform.
    private func launchGroup(_ group: SessionGroup) {
        let result = sessions.launch(group) { id in
            store.entry(id: id).map(store.resolved)
        }
        groupLaunchNotice = result.notice(for: group) { store.entry(id: $0)?.name }
    }

    /// The filter field's first arrow-key press while searching: pick an
    /// initial selection if there isn't one already, then hand keyboard focus
    /// to the host list so further arrow keys navigate it directly (native
    /// NSOutlineView row navigation once it's first responder).
    private func moveFocusToResults(selectFirst: Bool) {
        let tree = FolderTree.build(entries: filteredEntries,
                                    explicitFolders: store.explicitFolders,
                                    groups: filteredGroups)
        let ids = flattenedEntryIDs(from: tree)
        guard !ids.isEmpty else { return }
        if selection.isEmpty {
            selection = [selectFirst ? ids.first! : ids.last!]
        }
        sidebarFocusRequest += 1
    }

    /// Entry ids in the same depth-first order `HostOutlineView` renders them
    /// (folders then their entries, root entries last) — every one is visible
    /// while searching, since matching folders auto-expand.
    private func flattenedEntryIDs(from tree: SidebarTree) -> [UUID] {
        var ids: [UUID] = []
        func walk(_ nodes: [SidebarNode]) {
            for node in nodes {
                if let id = node.entryID { ids.append(id) }
                walk(node.children)
            }
        }
        walk(tree.folders.map(SidebarNode.folder) + tree.root.map(SidebarNode.entry))
        return ids
    }

    /// Opens every currently selected host (in sidebar order).
    private func openSelected(multiExec: Bool) {
        let entries = store.entries
            .filter { selection.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map(store.resolved)
        sessions.connectAll(entries, multiExec: multiExec)
    }

    /// Opens every host in a folder (and its subfolders).
    private func openFolder(_ path: String, multiExec: Bool) {
        sessions.connectAll(store.entriesInFolder(path), multiExec: multiExec)
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
                let data = try Data(contentsOf: url)
                // Prefer Portside's own export; fall back to MobaXterm parsing.
                if let doc = LibraryTransfer.decode(data) {
                    let added = store.importExport(entries: doc.entries ?? [],
                                                   folders: doc.folders ?? [],
                                                   macros: doc.macros ?? [],
                                                   credentialProfiles: doc.credentialProfiles ?? [])
                    importMessage = summary(sessions: added.sessions, macros: added.macros,
                                            profiles: added.profiles, skipped: 0)
                } else {
                    let parsed = try MobaXtermImporter.importFile(at: url)
                    let added = store.addImported(entries: parsed.entries, macros: parsed.macros)
                    importMessage = summary(sessions: added.sessions, macros: added.macros,
                                            profiles: 0, skipped: parsed.skippedNonSSH)
                }
            } catch {
                importMessage = "Import failed: \(error.localizedDescription)"
            }
        }
    }

    private func summary(sessions: Int, macros: Int, profiles: Int, skipped: Int) -> String {
        if sessions == 0 && macros == 0 && profiles == 0 {
            return "Nothing new to import — everything was already in the library."
        }
        var parts: [String] = []
        if sessions > 0 { parts.append("\(sessions) session\(sessions == 1 ? "" : "s")") }
        if macros > 0 { parts.append("\(macros) macro\(macros == 1 ? "" : "s")") }
        if profiles > 0 {
            parts.append("\(profiles) credential profile\(profiles == 1 ? "" : "s")")
        }
        var message = "Imported " + parts.joined(separator: ", ")
        if skipped > 0 { message += ", skipped \(skipped) non-SSH entries" }
        message += "."
        if profiles > 0 {
            // The one thing that doesn't travel, said plainly at the moment
            // it matters — otherwise the hosts look restored and simply fail
            // to authenticate later, with nothing connecting the two events.
            message += " Passwords aren't included in an export — set them in "
                     + "Settings ▸ Profiles and every host using them will work."
        }
        return message
    }

    private func exportSessions() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "portside-sessions.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try LibraryTransfer.encodeSessions(entries: store.entries,
                                                          folders: store.explicitFolders,
                                                          credentialProfiles: store.credentialProfiles)
            try data.write(to: url)
            let n = store.entries.count
            importMessage = "Exported \(n) session\(n == 1 ? "" : "s") to \(url.lastPathComponent)."
        } catch {
            importMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func exportMacros() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "portside-macros.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try LibraryTransfer.encodeMacros(store.macros)
            try data.write(to: url)
            let n = store.macros.count
            importMessage = "Exported \(n) macro\(n == 1 ? "" : "s") to \(url.lastPathComponent)."
        } catch {
            importMessage = "Export failed: \(error.localizedDescription)"
        }
    }
}

/// Home for standalone tools. Local shell and log search work today; the rest
/// are roadmap items surfaced as disabled rows so the section shows where
/// they'll live.
struct ToolsList: View {
    @EnvironmentObject var sessions: SessionManager
    @EnvironmentObject var tunnels: TunnelManager
    @EnvironmentObject var library: LibraryCommands
    let searchLogs: () -> Void
    let portForwarding: () -> Void
    let coverage: () -> Void
    let history: () -> Void

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
            Section("Network") {
                Button {
                    portForwarding()
                } label: {
                    HStack {
                        Label("Port Forwarding…", systemImage: "arrow.left.arrow.right")
                        if tunnels.activeCount > 0 {
                            Spacer()
                            Text("\(tunnels.activeCount)")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.green.opacity(0.25), in: Capsule())
                                .help("\(tunnels.activeCount) active tunnel(s)")
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Section("Inventory") {
                Button {
                    coverage()
                } label: {
                    Label("Coverage…", systemImage: "checklist")
                }
                .buttonStyle(.plain)
            }
            Section("History") {
                Button {
                    history()
                } label: {
                    Label("Commands & Connections…", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(.plain)
            }
            Section("Logs") {
                Button {
                    searchLogs()
                } label: {
                    Label("Search Logs…", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct MacroRow: View {
    @EnvironmentObject var store: SessionStore
    let macro: Macro
    let run: (Macro) -> Void
    let edit: (Macro) -> Void
    @State private var hovering = false

    var body: some View {
        Button {
            run(macro)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "play.circle")
                    .foregroundStyle(.secondary)
                Text(macro.name)
                    .lineLimit(1)
                Spacer(minLength: 4)
                // Same affordance the host rows use: always shown once set,
                // offered on hover before that.
                if macro.isFavorite || hovering {
                    Button {
                        store.setFavorite(!macro.isFavorite, macro: macro)
                    } label: {
                        Image(systemName: macro.isFavorite ? "star.fill" : "star")
                            .font(.caption)
                            .foregroundStyle(macro.isFavorite ? .yellow : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(macro.isFavorite
                          ? "Remove from the MultiExec bar"
                          : "Pin to the MultiExec bar")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(macro.text)
        .contextMenu {
            Button("Run") { run(macro) }
            Button("Edit…") { edit(macro) }
            Button(macro.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                store.setFavorite(!macro.isFavorite, macro: macro)
            }
            Divider()
            Button("Delete", role: .destructive) { store.delete(macro) }
        }
    }
}


/// Routes `LibraryCommands` tokens to the sidebar's own actions. A modifier
/// rather than inline `onChange` calls purely to keep `SidebarView.body`
/// type-checkable — the handlers themselves are one-liners into state the
/// sidebar owns.
private struct LibraryCommandRouter: ViewModifier {
    @ObservedObject var library: LibraryCommands
    let onNewSession: () -> Void
    let onNewFolder: () -> Void
    let onImport: () -> Void
    let onExportSessions: () -> Void
    let onExportMacros: () -> Void
    let onReimportSSHConfig: () -> Void
    let onExpandAll: () -> Void
    let onCollapseAll: () -> Void
    let onShowCoverage: () -> Void
    let onShowHistory: () -> Void
    let onSaveTabAsGroup: () -> Void
    let onCopyKeyToHosts: () -> Void
    let onRotateKey: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: library.newSession) { _, _ in onNewSession() }
            .onChange(of: library.newFolder) { _, _ in onNewFolder() }
            .onChange(of: library.importFile) { _, _ in onImport() }
            .onChange(of: library.exportSessions) { _, _ in onExportSessions() }
            .onChange(of: library.exportMacros) { _, _ in onExportMacros() }
            .onChange(of: library.reimportSSHConfig) { _, _ in onReimportSSHConfig() }
            .onChange(of: library.expandAllFolders) { _, _ in onExpandAll() }
            .onChange(of: library.collapseAllFolders) { _, _ in onCollapseAll() }
            .onChange(of: library.showCoverage) { _, _ in onShowCoverage() }
            .onChange(of: library.showHistory) { _, _ in onShowHistory() }
            .onChange(of: library.saveTabAsGroup) { _, _ in onSaveTabAsGroup() }
            .onChange(of: library.copyKeyToHosts) { _, _ in onCopyKeyToHosts() }
            .onChange(of: library.rotateKey) { _, _ in onRotateKey() }
    }
}

/// The library's five standalone sheets, in one modifier.
///
/// Not tidiness: `SidebarView.body` sits at the edge of what the type-checker
/// will solve, and adding a sixth `.sheet` to the chain failed to compile with
/// the error pointing at an unrelated alert two hundred lines away. Collapsing
/// the siblings into one modifier bought the room back — the same move
/// `GroupAlerts` and `LibraryCommandRouter` already document.
private struct LibrarySheets: ViewModifier {
    @Binding var coverage: Bool
    @Binding var history: Bool
    @Binding var logSearch: Bool
    @Binding var portForwarding: Bool
    @Binding var keyDistribution: Bool
    @Binding var keyRotation: Bool
    let keyPreselection: Set<UUID>
    let keyPath: String?
    let store: SessionStore
    let library: LibraryCommands
    let tunnels: TunnelManager

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $coverage) {
                // `library` as well as `store`: the empty state offers Import…,
                // and a missing @EnvironmentObject is a crash, not a blank view.
                CoverageView().environmentObject(store).environmentObject(library)
            }
            .sheet(isPresented: $history) {
                HistoryView().environmentObject(store)
            }
            .sheet(isPresented: $logSearch) {
                LogSearchView().environmentObject(store)
            }
            .sheet(isPresented: $portForwarding) {
                PortForwardingView().environmentObject(store).environmentObject(tunnels)
            }
            .sheet(isPresented: $keyDistribution) {
                // The sidebar selection is a starting point, not the decision —
                // the sheet's own confirmation names every host either way.
                KeyDistributionView(preselected: keyPreselection, preselectedKeyPath: keyPath)
                    .environmentObject(store)
            }
            .sheet(isPresented: $keyRotation) {
                KeyRotationView(preselected: keyPreselection).environmentObject(store)
            }
    }
}

/// The four group alerts, lifted out of `SidebarView`'s modifier chain.
///
/// Not organisation for its own sake: adding them inline pushed the chain past
/// what the type-checker will solve in reasonable time, and the error lands on
/// an unrelated alert several lines away rather than on the ones just added.
private struct GroupAlerts: ViewModifier {
    @Binding var savingGroup: Bool
    @Binding var newGroupName: String
    @Binding var newGroupFolder: String
    @Binding var renamingGroup: SessionGroup?
    @Binding var renameGroupName: String
    @Binding var groupToDelete: SessionGroup?
    @Binding var launchNotice: String?
    let store: SessionStore
    let sessions: SessionManager

    func body(content: Content) -> some View {
        content
    .alert("Save Tab as Group", isPresented: $savingGroup) {
        TextField("Name", text: $newGroupName)
        TextField("Folder", text: $newGroupFolder,
                  prompt: Text("e.g. prod/web — empty for top level"))
        Button("Save") {
            let name = newGroupName.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty,
               let group = sessions.groupFromSelectedTab(named: name, folder: newGroupFolder) {
                store.upsert(group)
                sessions.selectedTab?.groupID = group.id
            }
            newGroupName = ""
            newGroupFolder = ""
        }
        Button("Cancel", role: .cancel) { newGroupName = ""; newGroupFolder = "" }
    } message: {
        Text("Saves the panes in this tab and how they're arranged. "
             + "Opening it later brings the whole grid back, disarmed.")
    }
    .alert(
        "Rename Group",
        isPresented: Binding(
            get: { renamingGroup != nil },
            set: { if !$0 { renamingGroup = nil } }
        )
    ) {
        TextField("Name", text: $renameGroupName)
        Button("Rename") {
            if var group = renamingGroup {
                let name = renameGroupName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    group.name = name
                    store.upsert(group)
                }
            }
            renamingGroup = nil
        }
        Button("Cancel", role: .cancel) { renamingGroup = nil }
    }
    .alert(
        "Delete “\(groupToDelete?.name ?? "")”?",
        isPresented: Binding(
            get: { groupToDelete != nil },
            set: { if !$0 { groupToDelete = nil } }
        )
    ) {
        Button("Delete", role: .destructive) {
            if let group = groupToDelete { store.delete(group) }
            groupToDelete = nil
        }
        Button("Cancel", role: .cancel) { groupToDelete = nil }
    } message: {
        // Worth saying: deleting the group is not deleting the hosts.
        Text("The hosts in this group stay in your library — only the saved arrangement goes.")
    }
    .alert(
        "Group opened incomplete",
        isPresented: Binding(
            get: { launchNotice != nil },
            set: { if !$0 { launchNotice = nil } }
        )
    ) {
        Button("OK", role: .cancel) { launchNotice = nil }
    } message: {
        Text(launchNotice ?? "")
    }
    }
}
