import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Running as a bare SPM executable (no app bundle yet): promote to a
        // regular foreground app so the window shows and takes focus.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        RemoteFileEditor.purgeStaleCopies()
        AskpassInjector.purgeStaleDirectories()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stop watching and remove the temp copies of any files still checked
        // out for editing — they're unreachable once the app is gone.
        MainActor.assumeIsolated { RemoteFileEditor.shared.stopAll() }
    }
}

@main
struct PortsideApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = SessionStore()
    @StateObject private var sessions = SessionManager()
    @StateObject private var tunnels = TunnelManager()
    @StateObject private var updater = UpdaterViewModel()
    @StateObject private var library = LibraryCommands()
    @State private var settingsTab = "Appearance"
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private func open(_ url: URL) { NSWorkspace.shared.open(url) }

    /// Drives the app chrome's light/dark setting. `nil` means "follow system",
    /// which is `NSApplication`'s own way of saying it — not a third value.
    ///
    /// Fires on every appearance change, including font and theme edits, so it
    /// checks before assigning: reassigning the same appearance makes AppKit
    /// redraw every window for nothing, which is visible as a flicker while
    /// dragging the font-size slider.
    private func applyAppAppearance(_ appAppearance: AppAppearance) {
        let desired = appAppearance.nsAppearance
        guard NSApp.appearance?.name != desired?.name else { return }
        NSApp.appearance = desired
    }

    var body: some Scene {
        WindowGroup("Portside") {
            ContentView()
                .environmentObject(store)
                .environmentObject(sessions)
                .environmentObject(tunnels)
                .environmentObject(library)
                .frame(minWidth: 1000, minHeight: 640)
                .onAppear {
                    applyAppAppearance(store.appearance.appAppearance)
                    sessions.appearance = store.appearance
                    sessions.loggingSettings = store.logging
                    sessions.terminalSettings = store.terminal
                    sessions.connectionDefaults = store.defaults
                    RemoteFileEditor.shared.preferredEditor = store.defaults.remoteEditorURL
                    sessions.defaultProfileID = store.defaultProfileID
                    tunnels.defaultProfileID = store.defaultProfileID
                    sessions.onConnectionAttempt = { [weak store] entry, outcome in
                        store?.recordConnection(entry, outcome: outcome)
                    }
                    sessions.onWorkspaceChange = { [weak store] snapshot in
                        store?.saveWorkspace(snapshot)
                    }
                    sessions.onGroupLayoutChange = { [weak store] id, layout, gridView in
                        store?.updateLayout(groupID: id, layout: layout, wasGridView: gridView)
                    }
                    sessions.recordsCommands = store.history.keepCommandHistory
                    sessions.excludesProtectedFromRecording = store.history.excludeProtectedHosts
                    sessions.onCommand = { [weak store] event in
                        store?.recordCommand(event)
                    }
                    LogManager.runMaintenance(settings: store.logging)
                    tunnels.startAutoStartTunnels(forwards: store.forwards) { id in
                        store.entry(id: id).map(store.resolved)
                    }
                    // Reopen the last session's tabs (after appearance/logging/
                    // terminal are wired above, which restore's connect() uses).
                    sessions.bootstrapRestore(snapshot: store.workspace,
                                              mode: store.terminal.restoreMode) { id in
                        store.entry(id: id).map(store.resolved)
                    }
                }
                .onChange(of: store.appearance) { _, new in
                    applyAppAppearance(new.appAppearance)
                    sessions.applyAppearance(new)
                }
                .onChange(of: store.logging) { _, new in sessions.loggingSettings = new }
                .onChange(of: store.terminal) { _, new in sessions.applyTerminalSettings(new) }
                .onChange(of: store.defaults) { _, new in
                    sessions.connectionDefaults = new
                    RemoteFileEditor.shared.preferredEditor = new.remoteEditorURL
                }
                .onChange(of: store.defaultProfileID) { _, new in
                    sessions.defaultProfileID = new
                    tunnels.defaultProfileID = new
                }
                // Only affects sessions opened afterwards: the timeline is
                // attached when a session is created, so already-open tabs
                // keep whatever they started with.
                .onChange(of: store.history) { _, new in
                    sessions.recordsCommands = new.keepCommandHistory
                    sessions.excludesProtectedFromRecording = new.excludeProtectedHosts
                }
        }
        .commands {
            // Replaces the stock About panel, which answers "which version am
            // I running" but not "and what's in it" — until now only answerable
            // from a GitHub release page, or from an update dialog already
            // dismissed.
            CommandGroup(replacing: .appInfo) {
                Button("About Portside") { openWindow(id: "about") }
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            CommandGroup(after: .newItem) {
                Button("New Session…") { library.requestNewSession() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("New Folder…") { library.requestNewFolder() }
                Button("Save Tab as Group…") { library.requestSaveTabAsGroup() }
                    .disabled(sessions.selectedTab?.root == nil)
                Button("New Local Shell") { sessions.openLocalShell() }
                    .keyboardShortcut(shortcut(.newLocalShell))
                Button("Quick Connect…") { sessions.showQuickConnect = true }
                    .keyboardShortcut(shortcut(.quickConnect))
                Button("Close Tab") { sessions.closeSelectedTab() }
                    .keyboardShortcut(shortcut(.closeTab))
                    .disabled(sessions.selectedTab == nil)
                Button("Reopen Closed Tab") { sessions.reopenLastClosedTab() }
                    .keyboardShortcut(shortcut(.reopenClosedTab))
                    .disabled(sessions.closedTabs.isEmpty)
                // ⇧⌘T still walks back one at a time; this is for reaching
                // past the most recent one without reopening everything after
                // it first. Most-recent first, which is the reverse of how the
                // ring is stored.
                //
                // The empty case is a disabled placeholder rather than a
                // disabled menu: SwiftUI ignores `.disabled` on a `Menu` inside
                // a command group, so the submenu opens regardless and needs
                // something honest inside it.
                Menu("Recently Closed") {
                    if sessions.closedTabs.isEmpty {
                        Button("No Recently Closed Tabs") {}
                            .disabled(true)
                    } else {
                        ForEach(sessions.closedTabRing.mostRecentFirst) { closed in
                            Button(closed.menuEntry()) { sessions.reopenClosedTab(id: closed.id) }
                        }
                        Divider()
                        Button("Clear Recently Closed") { sessions.clearClosedTabs() }
                    }
                }
                Divider()
                Button("Import…") { library.requestImport() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Export Sessions…") { library.requestExportSessions() }
                    .disabled(store.entries.isEmpty)
                Button("Export Macros…") { library.requestExportMacros() }
                    .disabled(store.macros.isEmpty)
                Button("Re-import ~/.ssh/config") { library.requestReimportSSHConfig() }
            }
            // Directly under AppKit's own Undo/Redo, which is where an undo
            // belongs and — more to the point — the only place it reads
            // correctly. Those two are greyed out unless a text field has focus,
            // because Portside has no document undo manager; with the library
            // undo parked further down the menu past Find…, the greyed "Undo"
            // looked like the only one there was, while ⌥⌘Z plainly worked.
            CommandGroup(after: .undoRedo) {
                // Named rather than a bare "Undo Delete", so you can see which
                // delete you're about to take back before you take it back.
                //
                // Deliberately not ⌘Z: that belongs to whatever text field has
                // focus, and taking it would trade a working per-field undo for
                // a library-wide one firing at moments nobody intended.
                Button(store.deletedItems.mostRecent.map { "Undo Delete \($0.menuLabel)" }
                       ?? "Undo Delete") {
                    store.undoLastDelete()
                }
                .keyboardShortcut("z", modifiers: [.command, .option])
                .disabled(store.deletedItems.isEmpty)
                Menu("Recently Deleted") {
                    if store.deletedItems.isEmpty {
                        Button("Nothing Deleted") {}
                            .disabled(true)
                    } else {
                        ForEach(store.deletedItems.mostRecentFirst) { batch in
                            Button(batch.menuEntry()) { store.undoDelete(id: batch.id) }
                        }
                        Divider()
                        Button("Clear Recently Deleted") { store.clearDeletedItems() }
                    }
                }
            }
            CommandGroup(after: .textEditing) {
                Button("Find…") { sessions.selected?.toggleFind() }
                    .keyboardShortcut(shortcut(.find))
                    .disabled(sessions.selected == nil)
            }
            CommandGroup(after: .sidebar) {
                Button("Zoom In") { sessions.zoomIn() }
                    .keyboardShortcut(shortcut(.zoomIn))
                Button("Zoom Out") { sessions.zoomOut() }
                    .keyboardShortcut(shortcut(.zoomOut))
                Button("Actual Size") { sessions.resetZoom() }
                    .keyboardShortcut(shortcut(.actualSize))
                Divider()
                Button("Clear Buffer") { sessions.selected?.clearBuffer() }
                    .keyboardShortcut(shortcut(.clearBuffer))
                    .disabled(sessions.selected == nil)
                Button("Toggle MultiExec") { sessions.toggleMultiExec() }
                    .keyboardShortcut(shortcut(.toggleMultiExec))
                    // Must match the toolbar toggle's condition: arming also
                    // works from several single-pane tabs, which it gathers
                    // into Grid View first. Testing only `leaves.count` left
                    // ⇧⌘M dead in exactly that case.
                    .disabled((sessions.selectedTab?.leaves.count ?? 0) < 2 && sessions.tabs.count < 2)
                Menu("MultiExec Panes") {
                    ForEach(MultiExecBulkAction.allCases, id: \.self) { action in
                        Button(action.label) { sessions.applyBulkInclusion(action) }
                            .keyboardShortcut(shortcut(action.shortcutAction))
                            .disabled(!sessions.wouldChangeAnything(action))
                    }
                }
                .disabled(!(sessions.selectedTab?.broadcastArmed ?? false))
                Button("Toggle Grid View") { sessions.toggleGridView() }
                    .keyboardShortcut(shortcut(.toggleGridView))
                    .disabled(!sessions.canGridView)
                Divider()
                Button("Expand All Folders") { library.requestExpandAllFolders() }
                    .disabled(store.folders.isEmpty)
                Button("Collapse All Folders") { library.requestCollapseAllFolders() }
                    .disabled(store.folders.isEmpty)
                Divider()
                Button("Inventory Coverage…") { library.requestShowCoverage() }
                Button("History…") { library.requestShowHistory() }
                Divider()
            }
            CommandMenu("Pane") {
                Button("Split Right") { sessions.splitActivePane(.horizontal) }
                    .keyboardShortcut(shortcut(.splitRight))
                Button("Split Down") { sessions.splitActivePane(.vertical) }
                    .keyboardShortcut(shortcut(.splitDown))
                Button("Zoom Pane") { sessions.toggleZoom() }
                    .keyboardShortcut(shortcut(.zoomPane))
                Divider()
                Button("Focus Next Pane") { sessions.focusAdjacentPane(next: true) }
                    .keyboardShortcut(shortcut(.focusNextPane))
                Button("Focus Previous Pane") { sessions.focusAdjacentPane(next: false) }
                    .keyboardShortcut(shortcut(.focusPreviousPane))
                Divider()
                Button("Move Pane Forward") { sessions.moveActivePane(forward: true) }
                    .keyboardShortcut(shortcut(.movePaneForward))
                    .disabled(!sessions.canMoveActivePane(forward: true))
                Button("Move Pane Back") { sessions.moveActivePane(forward: false) }
                    .keyboardShortcut(shortcut(.movePaneBack))
                    .disabled(!sessions.canMoveActivePane(forward: false))
                Divider()
                Button("Toggle Pane in MultiExec") { sessions.toggleActivePaneInMultiExec() }
                    .keyboardShortcut(shortcut(.togglePaneInMultiExec))
                    .disabled(!(sessions.selectedTab?.broadcastArmed ?? false))
                Divider()
                Button("Close Pane") { sessions.closeActivePane() }
                    .keyboardShortcut(shortcut(.closePane))
            }
            // Replaces SwiftUI's stock "Portside Help", which opens nothing at
            // all — the single most conspicuous gap for anyone who reaches for
            // the menu bar first. The docs it points at already existed; they
            // were only reachable by browsing the repository.
            CommandGroup(replacing: .help) {
                Button("Portside Help") { open(Docs.index) }
                Button("Keyboard Shortcuts") {
                    settingsTab = "Shortcuts"
                    openSettings()
                }
                Divider()
                Button("Terminal Compatibility") { open(Docs.compatibility) }
                Button("Port Forwarding") { open(Docs.portForwarding) }
                Divider()
                Button("Release Notes") { openWindow(id: "about") }
                Button("Report an Issue…") { open(Docs.newIssue) }
                Button("Portside on GitHub") { open(Docs.repository) }
            }
            CommandGroup(after: .windowArrangement) {
                Divider()
                Button("Move Tab Forward") { sessions.moveSelectedTab(forward: true) }
                    .keyboardShortcut(shortcut(.moveTabForward))
                    .disabled(!sessions.canMoveSelectedTab(forward: true))
                Button("Move Tab Back") { sessions.moveSelectedTab(forward: false) }
                    .keyboardShortcut(shortcut(.moveTabBack))
                    .disabled(!sessions.canMoveSelectedTab(forward: false))
                Divider()
                Button("Show Next Tab") { sessions.selectNextTab() }
                    .keyboardShortcut(shortcut(.nextTab))
                Button("Show Previous Tab") { sessions.selectPreviousTab() }
                    .keyboardShortcut(shortcut(.previousTab))
                Menu("Go to Tab") {
                    ForEach(1...9, id: \.self) { n in
                        Button("Tab \(n)") { sessions.selectTab(at: n - 1) }
                            .keyboardShortcut(KeyEquivalent(Character(String(n))), modifiers: .command)
                    }
                }
            }
        }

        // Its own window rather than a sheet: release notes are something you
        // read alongside the app, and a modal you have to dismiss to go look at
        // the thing being described is the wrong shape.
        Window("About Portside", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Settings {
            // Selection is tracked only so the window can be resized when it
            // changes: SwiftUI sizes the Settings window once and then leaves
            // it, so each tab inherited the previous tab's height.
            TabView(selection: $settingsTab) {
                AppearanceSettingsView()
                    .environmentObject(store)
                    .tabItem { Label("Appearance", systemImage: "paintpalette") }
                    .tag("Appearance")
                TerminalSettingsView()
                    .environmentObject(store)
                    .tabItem { Label("Terminal", systemImage: "terminal") }
                    .tag("Terminal")
                ConnectionSettingsView()
                    .environmentObject(store)
                    .tabItem { Label("Connection", systemImage: "network") }
                    .tag("Connection")
                CredentialProfilesView()
                    .environmentObject(store)
                    .tabItem { Label("Profiles", systemImage: "person.badge.key") }
                    .tag("Profiles")
                RecordingSettingsView()
                    .environmentObject(store)
                    .tabItem { Label("Recording", systemImage: "record.circle") }
                    .tag("Recording")
                ShortcutsSettingsView()
                    .environmentObject(store)
                    .tabItem { Label("Shortcuts", systemImage: "keyboard") }
                    .tag("Shortcuts")
                UpdateSettingsView()
                    .environmentObject(updater)
                    .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
                    .tag("Updates")
            }
            .onChange(of: settingsTab) { _, _ in SettingsWindowSizer.fitToContent() }
        }
    }

    private func shortcut(_ action: ShortcutAction) -> KeyboardShortcut {
        let binding = store.keyBindings.binding(for: action)
        return KeyboardShortcut(binding.key.keyEquivalent, modifiers: binding.modifiers.eventModifiers)
    }
}
