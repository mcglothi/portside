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
                    .keyboardShortcut("t", modifiers: [.command])
                Button("Quick Connect…") { sessions.showQuickConnect = true }
                    .keyboardShortcut("k", modifiers: [.command])
            }
            CommandGroup(after: .textEditing) {
                Button("Find…") { sessions.selected?.toggleFind() }
                    .keyboardShortcut("f", modifiers: [.command])
                    .disabled(sessions.selected == nil)
            }
            CommandGroup(after: .sidebar) {
                Button("Zoom In") { sessions.zoomIn() }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Zoom Out") { sessions.zoomOut() }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { sessions.resetZoom() }
                    .keyboardShortcut("0", modifiers: .command)
                Divider()
            }
            CommandMenu("Pane") {
                Button("Split Right") { sessions.splitActivePane(.horizontal) }
                    .keyboardShortcut("d", modifiers: .command)
                Button("Split Down") { sessions.splitActivePane(.vertical) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Divider()
                Button("Focus Next Pane") { sessions.focusAdjacentPane(next: true) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Button("Focus Previous Pane") { sessions.focusAdjacentPane(next: false) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Divider()
                Button("Close Pane") { sessions.closeActivePane() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
            }
            CommandGroup(after: .windowArrangement) {
                Divider()
                Button("Show Next Tab") { sessions.selectNextTab() }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Show Previous Tab") { sessions.selectPreviousTab() }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
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
            }
        }
    }
}
