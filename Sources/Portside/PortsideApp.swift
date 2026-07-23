import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Running as a bare SPM executable (no app bundle yet): promote to a
        // regular foreground app so the window shows and takes focus.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct PortsideApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = SessionStore()
    @StateObject private var sessions = SessionManager()
    @StateObject private var tunnels = TunnelManager()
    @StateObject private var updater = UpdaterViewModel()

    var body: some Scene {
        WindowGroup("Portside") {
            ContentView()
                .environmentObject(store)
                .environmentObject(sessions)
                .environmentObject(tunnels)
                .frame(minWidth: 1000, minHeight: 640)
                .onAppear {
                    sessions.appearance = store.appearance
                    sessions.loggingSettings = store.logging
                    sessions.terminalSettings = store.terminal
                    sessions.onConnect = { [weak store] entry in
                        store?.recordConnection(entry)
                    }
                    sessions.onWorkspaceChange = { [weak store] snapshot in
                        store?.saveWorkspace(snapshot)
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
                .onChange(of: store.appearance) { _, new in sessions.applyAppearance(new) }
                .onChange(of: store.logging) { _, new in sessions.loggingSettings = new }
                .onChange(of: store.terminal) { _, new in sessions.applyTerminalSettings(new) }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            CommandGroup(after: .newItem) {
                Button("New Local Shell") { sessions.openLocalShell() }
                    .keyboardShortcut(shortcut(.newLocalShell))
                Button("Quick Connect…") { sessions.showQuickConnect = true }
                    .keyboardShortcut(shortcut(.quickConnect))
                Button("Reopen Closed Tab") { sessions.reopenLastClosedTab() }
                    .keyboardShortcut(shortcut(.reopenClosedTab))
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
            TabView {
                AppearanceSettingsView()
                    .environmentObject(store)
                    .tabItem { Label("Appearance", systemImage: "paintpalette") }
                TerminalSettingsView()
                    .environmentObject(store)
                    .tabItem { Label("Terminal", systemImage: "terminal") }
                ConnectionSettingsView()
                    .environmentObject(store)
                    .tabItem { Label("Connection", systemImage: "network") }
                LoggingSettingsView()
                    .environmentObject(store)
                    .tabItem { Label("Logging", systemImage: "doc.text.magnifyingglass") }
                ShortcutsSettingsView()
                    .environmentObject(store)
                    .tabItem { Label("Shortcuts", systemImage: "keyboard") }
                UpdateSettingsView()
                    .environmentObject(updater)
                    .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
            }
        }
    }

    private func shortcut(_ action: ShortcutAction) -> KeyboardShortcut {
        let binding = store.keyBindings.binding(for: action)
        return KeyboardShortcut(binding.key.keyEquivalent, modifiers: binding.modifiers.eventModifiers)
    }
}
