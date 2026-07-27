import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Running as a bare SPM executable (no app bundle yet): promote to a
        // regular foreground app so the window shows and takes focus.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        RemoteFileEditor.purgeStaleCopies()
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
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            CommandGroup(after: .newItem) {
                Button("New Session…") { library.requestNewSession() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("New Folder…") { library.requestNewFolder() }
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
                            Button(closed.menuLabel) { sessions.reopenClosedTab(id: closed.id) }
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
                    .disabled((sessions.selectedTab?.leaves.count ?? 0) < 2)
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
                Button("Close Pane") { sessions.closeActivePane() }
                    .keyboardShortcut(shortcut(.closePane))
            }
            CommandGroup(after: .windowArrangement) {
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
