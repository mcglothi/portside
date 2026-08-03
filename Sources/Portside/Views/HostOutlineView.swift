import AppKit
import SwiftUI

/// The Hosts sidebar, backed by an `NSOutlineView` so selection and drag are
/// native. SwiftUI's `List` couldn't give us range selection (shift-click /
/// shift-arrow) or reliable drag-to-folder — its selection fought the row's own
/// click handling, which is why the old list managed selection by hand. AppKit
/// handles all of that; this view bridges it back to the SwiftUI world.
///
/// Scope (see docs/host-sidebar-outline-plan.md): drag moves hosts and saved
/// groups between folders (no manual reordering — the tree is alphabetical),
/// and folders themselves aren't draggable; they expand/collapse and have
/// their own menu.
struct HostOutlineView: NSViewRepresentable {
    let tree: SidebarTree
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
    /// Bumped to expand or collapse every folder. Tokens rather than a bool
    /// because the action is an *event*, not a state the view can be in — the
    /// user can expand all, collapse one by hand, then expand all again.
    var expandAllRequest: Int = 0
    var collapseAllRequest: Int = 0

    // SwiftUI-state-driven actions the coordinator can't do on its own.
    let connect: (SessionEntry) -> Void
    /// Opens a saved group as one tab. Double-click, same as a host.
    var launchGroup: (SessionGroup) -> Void = { _ in }
    /// Rename/delete for a group's context menu.
    var renameGroup: (SessionGroup) -> Void = { _ in }
    var deleteGroup: (SessionGroup) -> Void = { _ in }
    let connectSelected: (_ multiExec: Bool) -> Void
    let edit: (SessionEntry) -> Void
    let openFolder: (_ path: String, _ multiExec: Bool) -> Void
    let newSubfolder: (String) -> Void
    let renameFolder: (_ path: String, _ currentName: String) -> Void

    static let dragType = NSPasteboard.PasteboardType("net.timmcg.portside.host")
    /// Groups drag on their own type rather than sharing the host one: a drop
    /// has to know which store collection an id belongs to, and a bare UUID
    /// doesn't say. Two types keeps that unambiguous and lets a mixed
    /// selection — some hosts, a group — move in one drag.
    static let groupDragType = NSPasteboard.PasteboardType("net.timmcg.portside.group")

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

        outline.registerForDraggedTypes([Self.dragType, Self.groupDragType])
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
        context.coordinator.performExpansionRequestsIfNeeded()
    }

    // MARK: - Coordinator

    @MainActor
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
        private var lastExpandAllRequest = 0
        private var lastCollapseAllRequest = 0
        /// Guards `expandedPaths` while a search-driven full-expand runs, so
        /// clearing the search doesn't leave every folder permanently expanded.
        private var isAutoExpanding = false

        init(_ parent: HostOutlineView) {
            self.parent = parent
            self.lastFocusRequest = parent.focusRequest
            self.lastExpandAllRequest = parent.expandAllRequest
            self.lastCollapseAllRequest = parent.collapseAllRequest
            super.init()
        }

        /// Expand/collapse everything. Deliberately *not* wrapped in
        /// `isAutoExpanding`: unlike the search-driven expand, this is the user
        /// asking, so the resulting notifications should record into
        /// `expandedPaths` and survive the next reload.
        /// Finds a folder node anywhere in the tree by its path.
        private func node(forFolderPath path: String) -> SidebarNode? {
            func search(_ nodes: [SidebarNode]) -> SidebarNode? {
                for node in nodes {
                    if node.folderPath == path { return node }
                    if let hit = search(node.children) { return hit }
                }
                return nil
            }
            return search(roots)
        }

        /// Expands or collapses one folder's whole subtree, including itself.
        private func setSubtreeExpanded(_ expanded: Bool, folderPath: String) {
            guard let outline, let node = node(forFolderPath: folderPath) else { return }
            if expanded {
                outline.expandItem(node, expandChildren: true)
            } else {
                outline.collapseItem(node, collapseChildren: true)
            }
        }

        func performExpansionRequestsIfNeeded() {
            guard let outline else { return }
            if lastExpandAllRequest != parent.expandAllRequest {
                lastExpandAllRequest = parent.expandAllRequest
                outline.expandItem(nil, expandChildren: true)
            }
            if lastCollapseAllRequest != parent.collapseAllRequest {
                lastCollapseAllRequest = parent.collapseAllRequest
                outline.collapseItem(nil, collapseChildren: true)
            }
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

        func rebuild(from tree: SidebarTree) {
            roots = tree.folders.map(SidebarNode.folder)
                + tree.rootGroups.map(SidebarNode.group)
                + tree.root.map(SidebarNode.entry)
            lastSignature = Self.signature(of: tree)
            outline?.reloadData()
            expandAfterReload()
        }

        /// Reload only when the tree actually changed; always reconcile selection.
        func sync(tree: SidebarTree, selection: Set<UUID>) {
            let signature = Self.signature(of: tree)
            if signature != lastSignature {
                let previouslyExpanded = expandedPaths
                roots = tree.folders.map(SidebarNode.folder)
                + tree.rootGroups.map(SidebarNode.group)
                + tree.root.map(SidebarNode.entry)
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
            var rows = IndexSet(selection.compactMap { id in
                let row = outline.row(forItem: nodesByEntryID[id])
                return row >= 0 ? row : nil
            })
            // `selection` is the SwiftUI binding, which carries hosts only —
            // the sidebar's actions are all host actions. Selected group rows
            // aren't in it and would be cleared by the next unrelated redraw,
            // so carry them through.
            for row in outline.selectedRowIndexes
            where (outline.item(atRow: row) as? SidebarNode)?.group != nil {
                rows.insert(row)
            }
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

        private static func signature(of tree: SidebarTree) -> String {
            var parts: [String] = []
            func line(_ entry: SessionEntry) {
                parts.append("e:\(entry.id):\(entry.name):\(entry.subtitle):\(entry.environment.rawValue):\(entry.isProtected):\(entry.isFavorite)")
            }
            // Groups belong in the signature too, or renaming, refiling or
            // deleting one leaves the outline showing the old state until some
            // unrelated change happens to force a rebuild.
            func groupLine(_ group: SessionGroup) {
                parts.append("g:\(group.id):\(group.name):\(group.paneCount):\(group.isFavorite)")
            }
            func walk(_ folders: [FolderNode]) {
                for folder in folders {
                    parts.append("f:\(folder.path)")
                    walk(folder.subfolders)
                    folder.groups.forEach(groupLine)
                    folder.entries.forEach(line)
                }
            }
            walk(tree.folders)
            tree.rootGroups.forEach(groupLine)
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
            let toggleFavorite: (() -> Void)? = node.group.map { group in
                { [weak self] in self?.parent.store.toggleFavorite(groupID: group.id) }
            } ?? node.entryID.map { entryID in
                { [weak self] in self?.parent.store.toggleFavorite(entryID) }
            }
            cell.configure(node: node, hostCount: node.isFolder ? parent.store.entriesInFolder(node.folderPath ?? "").count : 0,
                           toggleFavorite: toggleFavorite)
            return cell
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            // Hosts and groups. Folders still don't select — they expand,
            // collapse and right-click.
            //
            // Groups were excluded when they were read-only rows you
            // double-clicked. Now that they can be dragged between folders,
            // being unselectable meant a group couldn't be shift- or
            // ⌘-clicked into a drag with anything else, and worse, clicking one
            // gave no highlight at all — the row simply didn't respond.
            guard let node = item as? SidebarNode else { return false }
            return node.isEntry || node.group != nil
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
                  let node = outline.item(atRow: outline.clickedRow) as? SidebarNode else { return }
            if let group = node.group { return parent.launchGroup(group) }
            guard let entry = node.entry else { return }
            parent.connect(entry)
        }

        /// Returns true if the event was handled. Enter connects the selection;
        /// Delete removes it.
        func handleKeyDown(_ event: NSEvent) -> Bool {
            guard let outline, !outline.selectedRowIndexes.isEmpty else { return false }
            switch event.keyCode {
            case 36, 76: // Return, keypad Enter
                // A highlighted row has to do something on Return, and for a
                // group that means opening it — the same thing double-clicking
                // it does.
                for group in selectedGroups { parent.launchGroup(group) }
                if !selectedEntries.isEmpty { parent.connectSelected(false) }
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

        private var selectedGroups: [SessionGroup] {
            guard let outline else { return [] }
            return outline.selectedRowIndexes.compactMap {
                (outline.item(atRow: $0) as? SidebarNode)?.group
            }
        }

        private func deleteSelection() {
            let entries = selectedEntries
            let groups = selectedGroups
            guard !entries.isEmpty || !groups.isEmpty else { return }
            // One prompt covering the whole selection. Deleting a group throws
            // away an arrangement, not the hosts in it, which is why a lone
            // group deletes as quietly as a lone host.
            if entries.count + groups.count > 1,
               !confirmDelete(hosts: entries.count, groups: groups.count) { return }
            parent.store.delete(
                entryIDs: Set(entries.map(\.id)),
                groupIDs: Set(groups.map(\.id)),
                macroIDs: []
            )
        }

        private func confirmDelete(hosts: Int, groups: Int) -> Bool {
            let parts = [
                hosts > 0 ? "\(hosts) host\(hosts == 1 ? "" : "s")" : nil,
                groups > 0 ? "\(groups) group\(groups == 1 ? "" : "s")" : nil,
            ].compactMap { $0 }
            let alert = NSAlert()
            alert.messageText = "Delete \(parts.joined(separator: " and "))?"
            alert.informativeText = groups > 0
                ? "This removes them from your library. Deleting a group discards "
                  + "the saved arrangement, not the hosts in it. This can't be undone."
                : "This removes them from your library. This can't be undone."
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            return alert.runModal() == .alertFirstButtonReturn
        }

        // MARK: Drag & drop (host or group → folder)

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let node = item as? SidebarNode else { return nil }
            let pb = NSPasteboardItem()
            if let group = node.group {
                pb.setString(group.id.uuidString, forType: HostOutlineView.groupDragType)
            } else if let id = node.entryID {
                pb.setString(id.uuidString, forType: HostOutlineView.dragType)
            } else {
                return nil // folders aren't draggable
            }
            return pb
        }

        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                         proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            guard !draggedIDs(from: info).isEmpty || !draggedGroupIDs(from: info).isEmpty else {
                return []
            }
            // Always retarget to a drop *onto* a folder (or the whole outline for
            // top level) — we don't reorder, so between-row drops make no sense.
            let node = item as? SidebarNode
            if let node, node.isFolder {
                outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
                return .move
            }
            // Dropping on a host or a group means "into that row's folder".
            if let node, let folder = node.entry?.folder ?? node.group?.folder {
                if let folderNode = folderNode(forPath: folder) {
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
            let groupIDs = draggedGroupIDs(from: info)
            guard !ids.isEmpty || !groupIDs.isEmpty else { return false }
            let target = (item as? SidebarNode)?.folderPath ?? ""
            if !ids.isEmpty { parent.store.move(entryIDs: ids, toFolder: target) }
            if !groupIDs.isEmpty { parent.store.move(groupIDs: groupIDs, toFolder: target) }
            return true
        }

        private func draggedIDs(from info: NSDraggingInfo) -> Set<UUID> {
            let items = info.draggingPasteboard.pasteboardItems ?? []
            return Set(items.compactMap { item -> UUID? in
                item.string(forType: HostOutlineView.dragType).flatMap(UUID.init)
            })
        }

        private func draggedGroupIDs(from info: NSDraggingInfo) -> Set<UUID> {
            let items = info.draggingPasteboard.pasteboardItems ?? []
            return Set(items.compactMap { item -> UUID? in
                item.string(forType: HostOutlineView.groupDragType).flatMap(UUID.init)
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
            // A selection spanning both kinds gets its own menu. The host menu
            // counted hosts only, so right-clicking a host that was selected
            // alongside a group offered a plain single-host "Delete" — which
            // deleted the host, left the group, and asked nothing first.
            let groups = selectedGroups
            if !groups.isEmpty, outline.isRowSelected(outline.clickedRow),
               selectedEntries.count + groups.count > 1 {
                buildMixedSelectionMenu(menu, hosts: selectedEntries, groups: groups)
                return
            }
            switch node.kind {
            case .entry(let entry): buildEntryMenu(menu, clicked: entry)
            case .folder(let folder): buildFolderMenu(menu, folder: folder)
            case .group(let group): buildGroupMenu(menu, group: group)
            }
        }

        /// The menu for a selection containing at least one group and more
        /// than one row. Deliberately narrow: the bulk host actions
        /// (credential profile, environment, keychain) have no meaning for a
        /// group, and offering them next to a count that includes groups would
        /// misstate what they'd touch.
        private func buildMixedSelectionMenu(
            _ menu: NSMenu, hosts: [SessionEntry], groups: [SessionGroup]
        ) {
            let store = parent.store
            let total = hosts.count + groups.count

            if !hosts.isEmpty {
                menu.addItem(ClosureMenuItem(title: "Connect \(hosts.count) Host\(hosts.count == 1 ? "" : "s")") {
                    self.parent.connectSelected(false)
                })
                menu.addItem(ClosureMenuItem(title: "Connect \(hosts.count) in MultiExec") {
                    self.parent.connectSelected(true)
                })
            }
            let launch = parent.launchGroup
            menu.addItem(ClosureMenuItem(title: "Open \(groups.count) Group\(groups.count == 1 ? "" : "s")") {
                for group in groups { launch(group) }
            })
            menu.addItem(.separator())

            let hostIDs = Set(hosts.map(\.id))
            let groupIDs = Set(groups.map(\.id))
            let submenu = NSMenu()
            submenu.addItem(ClosureMenuItem(title: "Top Level") {
                if !hostIDs.isEmpty { store.move(entryIDs: hostIDs, toFolder: "") }
                store.move(groupIDs: groupIDs, toFolder: "")
            })
            if !store.folders.isEmpty { submenu.addItem(.separator()) }
            for target in store.folders {
                submenu.addItem(ClosureMenuItem(title: target) {
                    if !hostIDs.isEmpty { store.move(entryIDs: hostIDs, toFolder: target) }
                    store.move(groupIDs: groupIDs, toFolder: target)
                })
            }
            let moveItem = NSMenuItem(title: "Move \(total) Selected to", action: nil, keyEquivalent: "")
            moveItem.submenu = submenu
            menu.addItem(moveItem)

            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: "Delete \(total) Selected", role: .destructive) {
                guard self.confirmDelete(hosts: hosts.count, groups: groups.count) else { return }
                store.delete(entryIDs: hostIDs, groupIDs: groupIDs, macroIDs: [])
            })
        }

        private func buildGroupMenu(_ menu: NSMenu, group: SessionGroup) {
            let launch = parent.launchGroup
            let rename = parent.renameGroup
            let remove = parent.deleteGroup
            menu.addItem(ClosureMenuItem(title: "Open “\(group.name)”") { launch(group) })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: "Rename…") { rename(group) })
            addGroupMoveMenu(menu, group: group)
            let store = parent.store
            menu.addItem(ClosureMenuItem(
                title: group.isFavorite ? "Remove from Favorites" : "Add to Favorites"
            ) { store.toggleFavorite(groupID: group.id) })
            menu.addItem(ClosureMenuItem(title: "Delete Group") { remove(group) })
        }

        /// "Move to ▸" for a group — the keyboard-and-menu route to the same
        /// place dragging goes, for the same reason hosts have both.
        private func addGroupMoveMenu(_ menu: NSMenu, group: SessionGroup) {
            let store = parent.store
            let targets = store.folders.filter { $0 != group.folder }
            guard !targets.isEmpty || !group.folder.isEmpty else { return }

            let submenu = NSMenu()
            if !group.folder.isEmpty {
                submenu.addItem(ClosureMenuItem(title: "Top Level") {
                    store.move(groupID: group.id, toFolder: "")
                })
                if !targets.isEmpty { submenu.addItem(.separator()) }
            }
            for target in targets {
                submenu.addItem(ClosureMenuItem(title: target) {
                    store.move(groupID: group.id, toFolder: target)
                })
            }
            let item = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
            item.submenu = submenu
            menu.addItem(item)
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
                addEnvironmentMenu(menu, forSelection: selected)
                menu.addItem(ClosureMenuItem(title: "Add \(selected.count) Selected to Favorites") {
                    store.setFavorite(true, ids: selected)
                })
                menu.addItem(ClosureMenuItem(title: "Remove \(selected.count) Selected from Favorites") {
                    store.setFavorite(false, ids: selected)
                })
                menu.addItem(.separator())
                menu.addItem(ClosureMenuItem(title: "Delete \(selected.count) Selected") {
                    if self.confirmDelete(hosts: selected.count, groups: 0) { store.delete(ids: selected) }
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
            addEnvironmentMenu(menu, forSelection: [entry.id])
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

        /// "Set Environment ▸", the tagging half of classifying a large
        /// imported inventory. Mirrors the credential-profile submenu so both
        /// bulk actions read the same on a selection and on a folder.
        private func addEnvironmentMenu(_ menu: NSMenu, forSelection ids: Set<UUID>) {
            let store = parent.store
            let submenu = NSMenu()
            for environment in HostEnvironment.allCases where environment != .none {
                submenu.addItem(ClosureMenuItem(title: environment.label) {
                    store.setEnvironment(environment, ids: ids)
                })
            }
            submenu.addItem(.separator())
            submenu.addItem(ClosureMenuItem(title: "None") {
                store.setEnvironment(.none, ids: ids)
            })
            let item = NSMenuItem(title: "Set Environment", action: nil, keyEquivalent: "")
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
                addEnvironmentMenu(menu, forSelection: Set(inFolder.map(\.id)))
                menu.addItem(.separator())
            }
            // Scoped to this folder's own subtree rather than the whole
            // library — the global versions live in View and the toolbar, and
            // repeating them here would be the less useful of the two.
            //
            // Shown unconditionally: gating on "has subfolders" made the menu
            // silently vary with structure, so a library of top-level folders
            // never saw it at all. With no subfolders these simply open or
            // close the folder itself, which is what the labels say.
            menu.addItem(ClosureMenuItem(title: "Expand All in \(folder.name)") {
                self.setSubtreeExpanded(true, folderPath: folder.path)
            })
            menu.addItem(ClosureMenuItem(title: "Collapse All in \(folder.name)") {
                self.setSubtreeExpanded(false, folderPath: folder.path)
            })
            menu.addItem(.separator())
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
        case group(SessionGroup)
    }
    let kind: Kind
    let children: [SidebarNode]

    private init(kind: Kind, children: [SidebarNode]) {
        self.kind = kind
        self.children = children
    }

    static func folder(_ node: FolderNode) -> SidebarNode {
        // Groups first: a group opens several of the hosts below it, so it
        // reads as the folder's heading rather than one more item in the list.
        let kids = node.subfolders.map(folder) + node.groups.map(group) + node.entries.map(entry)
        return SidebarNode(kind: .folder(node), children: kids)
    }

    static func entry(_ entry: SessionEntry) -> SidebarNode {
        SidebarNode(kind: .entry(entry), children: [])
    }

    static func group(_ group: SessionGroup) -> SidebarNode {
        SidebarNode(kind: .group(group), children: [])
    }

    var isFolder: Bool { if case .folder = kind { return true }; return false }
    var isEntry: Bool { if case .entry = kind { return true }; return false }

    var entry: SessionEntry? { if case .entry(let e) = kind { return e }; return nil }
    var entryID: UUID? { entry?.id }
    var group: SessionGroup? { if case .group(let g) = kind { return g }; return nil }
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
            case .group(let group): groupRow(group)
            case .none: EmptyView()
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        // Never let a row be compressed below the height its text needs. The
        // outline sizes rows from this view's intrinsic height, and a row whose
        // content is *only* two lines of text — a group — measured shorter than
        // a host row, which carries transport and environment badges in the
        // same HStack. The result was a clipped descender on the second line:
        // "5 panes" with the bottom shaved off, while the host beneath it sat
        // comfortably.
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, minHeight: Self.minimumRowHeight, alignment: .leading)
    }

    /// Keeps every row kind the same height regardless of what it carries, so
    /// the list reads as one list rather than three that happen to be adjacent.
    /// Two lines of text plus the container's own padding.
    private static let minimumRowHeight: CGFloat = 38

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

    /// A saved group. Distinct glyph and a pane count, because the thing that
    /// matters at a glance is "this opens several at once" and how many.
    private func groupRow(_ group: SessionGroup) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "square.grid.2x2.fill")
                .foregroundStyle(model.emphasized ? .white : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.name).foregroundStyle(primary)
                Text("\(group.paneCount) pane\(group.paneCount == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(secondary)
            }
            Spacer(minLength: 4)
            if group.isFavorite || hoveringEntry {
                Button { model.toggleFavorite?() } label: {
                    Image(systemName: group.isFavorite ? "star.fill" : "star")
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(group.isFavorite ? .yellow : (model.emphasized ? .white.opacity(0.7) : .secondary))
                .help(group.isFavorite ? "Remove from Favorites" : "Add to Favorites")
            }
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
