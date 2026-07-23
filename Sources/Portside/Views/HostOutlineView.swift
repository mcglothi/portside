import AppKit
import SwiftUI

/// The Hosts sidebar, backed by an `NSOutlineView` so selection and drag are
/// native. SwiftUI's `List` couldn't give us range selection (shift-click /
/// shift-arrow) or reliable drag-to-folder — its selection fought the row's own
/// click handling, which is why the old list managed selection by hand. AppKit
/// handles all of that; this view bridges it back to the SwiftUI world.
///
/// Scope (see docs/host-sidebar-outline-plan.md): drag moves hosts between
/// folders only (no manual reordering — the tree is alphabetical), and only
/// hosts are selectable (folders expand/collapse and have their own menu).
struct HostOutlineView: NSViewRepresentable {
    let tree: (root: [SessionEntry], folders: [FolderNode])
    @Binding var selection: Set<UUID>
    let store: SessionStore
    /// True while a host filter is active — every folder in the (already
    /// narrowed) tree expands automatically so matches aren't hidden behind a
    /// manual disclosure triangle.
    var searching: Bool = false
    /// Bumped by the filter field's first arrow-key press to hand keyboard
    /// focus to the outline, so subsequent arrow keys navigate rows natively
    /// (NSOutlineView already handles that once it's first responder) instead
    /// of staying trapped in the text field.
    var focusRequest: Int = 0

    // SwiftUI-state-driven actions the coordinator can't do on its own.
    let connect: (SessionEntry) -> Void
    let connectSelected: (_ multiExec: Bool) -> Void
    let edit: (SessionEntry) -> Void
    let openFolder: (_ path: String, _ multiExec: Bool) -> Void
    let newSubfolder: (String) -> Void
    let renameFolder: (_ path: String, _ currentName: String) -> Void

    static let dragType = NSPasteboard.PasteboardType("net.timmcg.portside.host")

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = KeyableOutlineView()
        outline.headerView = nil
        outline.autoresizesOutlineColumn = false
        outline.indentationPerLevel = 14
        outline.usesAutomaticRowHeights = true
        outline.style = .sourceList
        outline.allowsMultipleSelection = true
        outline.allowsEmptySelection = true
        outline.floatsGroupRows = false

        let column = NSTableColumn(identifier: .init("host"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column

        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.handleDoubleClick(_:))

        outline.registerForDraggedTypes([Self.dragType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)

        let menu = NSMenu()
        menu.delegate = context.coordinator
        outline.menu = menu

        outline.onKeyDown = { [weak coordinator = context.coordinator] event in
            coordinator?.handleKeyDown(event) ?? false
        }

        context.coordinator.outline = outline
        context.coordinator.rebuild(from: tree)

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.sync(tree: tree, selection: selection)
        context.coordinator.performFocusRequestIfNeeded()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        var parent: HostOutlineView
        weak var outline: NSOutlineView?

        private var roots: [SidebarNode] = []
        /// Folder paths the user has expanded, tracked so a reload can restore
        /// them (NSOutlineView keys expansion on item identity, which we rebuild).
        private var expandedPaths: Set<String> = []
        /// Signature of the last tree we loaded, to skip needless reloads.
        private var lastSignature = ""
        /// Guards selection write-back while we apply selection programmatically.
        private var applyingSelection = false
        /// Last `focusRequest` token seen, to detect the filter field's "hand
        /// me focus" bump without acting on it more than once.
        private var lastFocusRequest = 0
        /// Guards `expandedPaths` while a search-driven full-expand runs, so
        /// clearing the search doesn't leave every folder permanently expanded.
        private var isAutoExpanding = false

        init(_ parent: HostOutlineView) {
            self.parent = parent
            self.lastFocusRequest = parent.focusRequest
            super.init()
        }

        /// Hands keyboard focus to the outline when the filter field bumps
        /// `focusRequest` — the selection is already applied by `sync` above,
        /// so arrow keys pick up navigating natively from there.
        func performFocusRequestIfNeeded() {
            guard lastFocusRequest != parent.focusRequest, let outline else { return }
            lastFocusRequest = parent.focusRequest
            outline.window?.makeFirstResponder(outline)
        }

        // MARK: Tree building

        func rebuild(from tree: (root: [SessionEntry], folders: [FolderNode])) {
            roots = tree.folders.map(SidebarNode.folder) + tree.root.map(SidebarNode.entry)
            lastSignature = Self.signature(of: tree)
            outline?.reloadData()
            expandAfterReload()
        }

        /// Reload only when the tree actually changed; always reconcile selection.
        func sync(tree: (root: [SessionEntry], folders: [FolderNode]), selection: Set<UUID>) {
            let signature = Self.signature(of: tree)
            if signature != lastSignature {
                let previouslyExpanded = expandedPaths
                roots = tree.folders.map(SidebarNode.folder) + tree.root.map(SidebarNode.entry)
                lastSignature = signature
                outline?.reloadData()
                expandedPaths = previouslyExpanded
                expandAfterReload()
            }
            applySelection(selection)
        }

        /// While searching, everything in the (already narrowed) tree expands
        /// automatically; otherwise restore the user's own expand/collapse state.
        private func expandAfterReload() {
            guard let outline else { return }
            if parent.searching {
                isAutoExpanding = true
                outline.expandItem(nil, expandChildren: true)
                isAutoExpanding = false
            } else {
                restoreExpansion()
            }
        }

        private func restoreExpansion() {
            guard let outline else { return }
            func expand(_ nodes: [SidebarNode]) {
                for node in nodes {
                    if case .folder(let folder) = node.kind, expandedPaths.contains(folder.path) {
                        outline.expandItem(node)
                        expand(node.children)
                    }
                }
            }
            expand(roots)
        }

        private func applySelection(_ selection: Set<UUID>) {
            guard let outline else { return }
            let rows = IndexSet(selection.compactMap { id in
                let row = outline.row(forItem: nodesByEntryID[id])
                return row >= 0 ? row : nil
            })
            let current = outline.selectedRowIndexes
            guard rows != current else { return }
            applyingSelection = true
            outline.selectRowIndexes(rows, byExtendingSelection: false)
            applyingSelection = false
        }

        /// Fast lookup for selection restore; rebuilt lazily per access.
        private var nodesByEntryID: [UUID: SidebarNode] {
            var map: [UUID: SidebarNode] = [:]
            func walk(_ nodes: [SidebarNode]) {
                for node in nodes {
                    if case .entry(let entry) = node.kind { map[entry.id] = node }
                    walk(node.children)
                }
            }
            walk(roots)
            return map
        }

        private static func signature(of tree: (root: [SessionEntry], folders: [FolderNode])) -> String {
            var parts: [String] = []
            func line(_ entry: SessionEntry) {
                parts.append("e:\(entry.id):\(entry.name):\(entry.subtitle):\(entry.environment.rawValue):\(entry.isProtected):\(entry.isFavorite)")
            }
            func walk(_ folders: [FolderNode]) {
                for folder in folders {
                    parts.append("f:\(folder.path)")
                    walk(folder.subfolders)
                    folder.entries.forEach(line)
                }
            }
            walk(tree.folders)
            tree.root.forEach(line)
            return parts.joined(separator: "|")
        }

        // MARK: NSOutlineViewDataSource

        private func children(of item: Any?) -> [SidebarNode] {
            guard let node = item as? SidebarNode else { return roots }
            return node.children
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            children(of: item).count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            children(of: item)[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? SidebarNode)?.isFolder ?? false
        }

        // MARK: NSOutlineViewDelegate

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? SidebarNode else { return nil }
            let id = NSUserInterfaceItemIdentifier("row")
            let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? HostRowCell) ?? HostRowCell()
            cell.identifier = id
            let toggleFavorite: (() -> Void)? = node.entryID.map { entryID in
                { [weak self] in self?.parent.store.toggleFavorite(entryID) }
            }
            cell.configure(node: node, hostCount: node.isFolder ? parent.store.entriesInFolder(node.folderPath ?? "").count : 0,
                           toggleFavorite: toggleFavorite)
            return cell
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            // Hosts only: folders expand/collapse and right-click, but never join
            // the multi-selection.
            (item as? SidebarNode)?.isEntry ?? false
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !applyingSelection, let outline else { return }
            let ids = outline.selectedRowIndexes.compactMap { row -> UUID? in
                (outline.item(atRow: row) as? SidebarNode)?.entryID
            }
            let newSelection = Set(ids)
            if newSelection != parent.selection {
                DispatchQueue.main.async { self.parent.selection = newSelection }
            }
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !isAutoExpanding else { return }
            if let node = notification.userInfo?["NSObject"] as? SidebarNode, let path = node.folderPath {
                expandedPaths.insert(path)
            }
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !isAutoExpanding else { return }
            if let node = notification.userInfo?["NSObject"] as? SidebarNode, let path = node.folderPath {
                expandedPaths.remove(path)
            }
        }

        // MARK: Double-click / keyboard

        @objc func handleDoubleClick(_ sender: Any?) {
            guard let outline, outline.clickedRow >= 0,
                  let entry = (outline.item(atRow: outline.clickedRow) as? SidebarNode)?.entry else { return }
            parent.connect(entry)
        }

        /// Returns true if the event was handled. Enter connects the selection;
        /// Delete removes it.
        func handleKeyDown(_ event: NSEvent) -> Bool {
            guard let outline, !outline.selectedRowIndexes.isEmpty else { return false }
            switch event.keyCode {
            case 36, 76: // Return, keypad Enter
                parent.connectSelected(false)
                return true
            case 51, 117: // Delete, forward-delete
                deleteSelection()
                return true
            default:
                return false
            }
        }

        private var selectedEntries: [SessionEntry] {
            guard let outline else { return [] }
            return outline.selectedRowIndexes.compactMap {
                (outline.item(atRow: $0) as? SidebarNode)?.entry
            }
        }

        private func deleteSelection() {
            let entries = selectedEntries
            guard !entries.isEmpty else { return }
            if entries.count == 1 {
                parent.store.delete(entries[0])
            } else if confirmDelete(count: entries.count) {
                parent.store.delete(ids: Set(entries.map(\.id)))
            }
        }

        private func confirmDelete(count: Int) -> Bool {
            let alert = NSAlert()
            alert.messageText = "Delete \(count) hosts?"
            alert.informativeText = "This removes them from your library. This can't be undone."
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            return alert.runModal() == .alertFirstButtonReturn
        }

        // MARK: Drag & drop (host → folder only)

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let id = (item as? SidebarNode)?.entryID else { return nil } // folders aren't draggable
            let pb = NSPasteboardItem()
            pb.setString(id.uuidString, forType: HostOutlineView.dragType)
            return pb
        }

        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                         proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            guard draggedIDs(from: info).isEmpty == false else { return [] }
            // Always retarget to a drop *onto* a folder (or the whole outline for
            // top level) — we don't reorder, so between-row drops make no sense.
            let node = item as? SidebarNode
            if let node, node.isFolder {
                outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
                return .move
            }
            if let node, let entry = node.entry {
                // Dropping on a host means "into that host's folder".
                if let folderNode = folderNode(forPath: entry.folder) {
                    outlineView.setDropItem(folderNode, dropChildIndex: NSOutlineViewDropOnItemIndex)
                } else {
                    outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
                }
                return .move
            }
            // Root / empty space → top level.
            outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .move
        }

        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                         item: Any?, childIndex index: Int) -> Bool {
            let ids = draggedIDs(from: info)
            guard !ids.isEmpty else { return false }
            let target = (item as? SidebarNode)?.folderPath ?? ""
            parent.store.move(entryIDs: ids, toFolder: target)
            return true
        }

        private func draggedIDs(from info: NSDraggingInfo) -> Set<UUID> {
            let items = info.draggingPasteboard.pasteboardItems ?? []
            return Set(items.compactMap { item -> UUID? in
                item.string(forType: HostOutlineView.dragType).flatMap(UUID.init)
            })
        }

        private func folderNode(forPath path: String) -> SidebarNode? {
            guard !path.isEmpty else { return nil }
            var found: SidebarNode?
            func walk(_ nodes: [SidebarNode]) {
                for node in nodes {
                    if node.folderPath == path { found = node; return }
                    walk(node.children)
                }
            }
            walk(roots)
            return found
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let outline, outline.clickedRow >= 0,
                  let node = outline.item(atRow: outline.clickedRow) as? SidebarNode else { return }
            switch node.kind {
            case .entry(let entry): buildEntryMenu(menu, clicked: entry)
            case .folder(let folder): buildFolderMenu(menu, folder: folder)
            }
        }

        private func buildEntryMenu(_ menu: NSMenu, clicked entry: SessionEntry) {
            let selected = Set(selectedEntries.map(\.id))
            let store = parent.store
            let multi = selected.count > 1 && selected.contains(entry.id)

            if multi {
                menu.addItem(ClosureMenuItem(title: "Connect \(selected.count) Selected") {
                    self.parent.connectSelected(false)
                })
                menu.addItem(ClosureMenuItem(title: "Connect \(selected.count) in MultiExec") {
                    self.parent.connectSelected(true)
                })
                menu.addItem(.separator())
                addMoveMenu(menu, forSelection: selected, currentFolder: nil)
                menu.addItem(ClosureMenuItem(title: "Save Password in Keychain for \(selected.count) Selected") {
                    store.setSavePassword(true, ids: selected)
                })
                addCredentialProfileMenu(menu, forSelection: selected)
                menu.addItem(ClosureMenuItem(title: "Add \(selected.count) Selected to Favorites") {
                    store.setFavorite(true, ids: selected)
                })
                menu.addItem(ClosureMenuItem(title: "Remove \(selected.count) Selected from Favorites") {
                    store.setFavorite(false, ids: selected)
                })
                menu.addItem(.separator())
                menu.addItem(ClosureMenuItem(title: "Delete \(selected.count) Selected") {
                    if self.confirmDelete(count: selected.count) { store.delete(ids: selected) }
                })
                return
            }

            menu.addItem(ClosureMenuItem(title: "Connect") { self.parent.connect(entry) })
            menu.addItem(ClosureMenuItem(title: "Edit…") { self.parent.edit(entry) })
            menu.addItem(ClosureMenuItem(title: "Duplicate") { store.duplicate(entry) })
            menu.addItem(ClosureMenuItem(title: entry.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                store.toggleFavorite(entry.id)
            })
            addMoveMenu(menu, forSelection: [entry.id], currentFolder: entry.folder)
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: "Delete", role: .destructive) { store.delete(entry) })
        }

        /// "Move to ▸" submenu of every folder the selection isn't already in,
        /// plus Top Level when applicable.
        private func addMoveMenu(_ menu: NSMenu, forSelection ids: Set<UUID>, currentFolder: String?) {
            let store = parent.store
            var targets = store.folders
            if let currentFolder { targets.removeAll { $0 == currentFolder } }
            let inFolder = currentFolder.map { !$0.isEmpty } ?? true
            guard !targets.isEmpty || inFolder else { return }

            let submenu = NSMenu()
            if inFolder {
                submenu.addItem(ClosureMenuItem(title: "Top Level") { store.move(entryIDs: ids, toFolder: "") })
                if !targets.isEmpty { submenu.addItem(.separator()) }
            }
            for target in targets {
                submenu.addItem(ClosureMenuItem(title: target) { store.move(entryIDs: ids, toFolder: target) })
            }
            let item = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
            item.submenu = submenu
            menu.addItem(item)
        }

        /// "Apply Credential Profile ▸" submenu (plus "None" to clear) for a
        /// selection or a whole folder. No-ops (adds nothing) when there are
        /// no profiles yet — nothing useful to offer.
        private func addCredentialProfileMenu(_ menu: NSMenu, forSelection ids: Set<UUID>) {
            let store = parent.store
            guard !store.credentialProfiles.isEmpty else { return }
            let submenu = NSMenu()
            for profile in store.credentialProfiles {
                submenu.addItem(ClosureMenuItem(title: profile.name) {
                    store.applyCredentialProfile(profile.id, to: ids)
                })
            }
            submenu.addItem(.separator())
            submenu.addItem(ClosureMenuItem(title: "None") {
                store.applyCredentialProfile(nil, to: ids)
            })
            let item = NSMenuItem(title: "Apply Credential Profile", action: nil, keyEquivalent: "")
            item.submenu = submenu
            menu.addItem(item)
        }

        private func buildFolderMenu(_ menu: NSMenu, folder: FolderNode) {
            let store = parent.store
            let inFolder = store.entriesInFolder(folder.path)
            let count = inFolder.count
            if count > 0 {
                menu.addItem(ClosureMenuItem(title: "Open All (\(count))") { self.parent.openFolder(folder.path, false) })
                menu.addItem(ClosureMenuItem(title: "Open All in MultiExec") { self.parent.openFolder(folder.path, true) })
                menu.addItem(.separator())
                addCredentialProfileMenu(menu, forSelection: Set(inFolder.map(\.id)))
                menu.addItem(.separator())
            }
            menu.addItem(ClosureMenuItem(title: "New Subfolder…") { self.parent.newSubfolder(folder.path) })
            menu.addItem(ClosureMenuItem(title: "Rename…") { self.parent.renameFolder(folder.path, folder.name) })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: "Delete Folder", role: .destructive) { store.deleteFolder(folder.path) })
        }
    }
}

// MARK: - Item model

/// Reference-typed node so NSOutlineView has stable object identity. Rebuilt on
/// each tree change; expansion/selection are reconciled by folder path / entry id.
final class SidebarNode {
    enum Kind {
        case folder(FolderNode)
        case entry(SessionEntry)
    }
    let kind: Kind
    let children: [SidebarNode]

    private init(kind: Kind, children: [SidebarNode]) {
        self.kind = kind
        self.children = children
    }

    static func folder(_ node: FolderNode) -> SidebarNode {
        let kids = node.subfolders.map(folder) + node.entries.map(entry)
        return SidebarNode(kind: .folder(node), children: kids)
    }

    static func entry(_ entry: SessionEntry) -> SidebarNode {
        SidebarNode(kind: .entry(entry), children: [])
    }

    var isFolder: Bool { if case .folder = kind { return true }; return false }
    var isEntry: Bool { if case .entry = kind { return true }; return false }

    var entry: SessionEntry? { if case .entry(let e) = kind { return e }; return nil }
    var entryID: UUID? { entry?.id }
    var folderPath: String? { if case .folder(let f) = kind { return f.path }; return nil }
}

// MARK: - Row cell

/// Drives the SwiftUI row content and flips text colors when the row is drawn
/// with an emphasized (selected) background.
private final class RowModel: ObservableObject {
    @Published var node: SidebarNode?
    @Published var hostCount = 0
    @Published var emphasized = false
    @Published var toggleFavorite: (() -> Void)?
}

private final class HostRowCell: NSTableCellView {
    private let model = RowModel()
    private var hosting: NSHostingView<SidebarRowLabel>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let view = NSHostingView(rootView: SidebarRowLabel(model: model))
        view.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 13.0, *) { view.sizingOptions = [.intrinsicContentSize] }
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        hosting = view
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(node: SidebarNode, hostCount: Int, toggleFavorite: (() -> Void)? = nil) {
        model.node = node
        model.hostCount = hostCount
        model.toggleFavorite = toggleFavorite
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { model.emphasized = (backgroundStyle == .emphasized) }
    }
}

private struct SidebarRowLabel: View {
    @ObservedObject var model: RowModel
    @State private var hoveringEntry = false

    var body: some View {
        Group {
            switch model.node?.kind {
            case .entry(let entry): entryRow(entry)
            case .folder(let folder): folderRow(folder)
            case .none: EmptyView()
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var primary: Color { model.emphasized ? .white : .primary }
    private var secondary: Color { model.emphasized ? .white.opacity(0.85) : .secondary }

    private func entryRow(_ entry: SessionEntry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: entry.icon).foregroundStyle(model.emphasized ? .white : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).foregroundStyle(primary)
                Text(entry.subtitle).font(.caption).foregroundStyle(secondary)
            }
            Spacer(minLength: 4)
            if entry.isFavorite || hoveringEntry {
                Button { model.toggleFavorite?() } label: {
                    Image(systemName: entry.isFavorite ? "star.fill" : "star")
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(entry.isFavorite ? .yellow : (model.emphasized ? .white.opacity(0.7) : .secondary))
                .help(entry.isFavorite ? "Remove from Favorites" : "Add to Favorites")
            }
            if entry.isProtected {
                Image(systemName: "lock.fill").font(.caption2)
                    .foregroundStyle(model.emphasized ? .white : .secondary).help("Protected host")
            }
            TransportBadge(entry: entry)
            EnvironmentBadge(environment: entry.environment)
        }
        .onHover { hoveringEntry = $0 }
    }

    private func folderRow(_ folder: FolderNode) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").foregroundStyle(model.emphasized ? .white : .secondary)
            Text(folder.name).foregroundStyle(primary)
            Spacer(minLength: 4)
            if model.hostCount > 0 {
                Text("\(model.hostCount)").font(.caption).foregroundStyle(secondary)
            }
        }
    }
}

// MARK: - Supporting AppKit types

/// Menu item that runs a closure. `role: .destructive` doesn't restyle on macOS
/// (AppKit has no destructive menu role); it's accepted for call-site parity.
final class ClosureMenuItem: NSMenuItem {
    enum Role { case normal, destructive }
    private let handler: () -> Void

    init(title: String, role: Role = .normal, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func fire() { handler() }
}

/// Outline view that forwards key events so Return/Delete can act on the
/// selection. Returns of `false` from the handler fall through to AppKit.
final class KeyableOutlineView: NSOutlineView {
    var onKeyDown: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }
}
