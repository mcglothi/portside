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
                    sessions.onConnect = { [weak store] entry in
                        store?.recordConnection(entry)
                    }
                    LogManager.runMaintenance(settings: store.logging)
                    tunnels.startAutoStartTunnels(forwards: store.forwards) { id in
                        store.entry(id: id).map(store.resolved)
                    }
                }
                .onChange(of: store.appearance) { _, new in sessions.applyAppearance(new) }
                .onChange(of: store.logging) { _, new in sessions.loggingSettings = new }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            CommandGroup(after: .newItem) {
                Button("New Local Shell") { sessions.openLocalShell() }
                    .keyboardShortcut("t", modifiers: [.command])
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
        }

        Settings {
            TabView {
                AppearanceSettingsView()
                    .environmentObject(store)
                    .tabItem { Label("Appearance", systemImage: "paintpalette") }
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
