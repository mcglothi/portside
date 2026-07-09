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

    var body: some Scene {
        WindowGroup("Portside") {
            ContentView()
                .environmentObject(store)
                .environmentObject(sessions)
                .frame(minWidth: 1000, minHeight: 640)
                .onAppear { sessions.appearance = store.appearance }
                .onChange(of: store.appearance) { _, new in sessions.applyAppearance(new) }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Local Shell") { sessions.openLocalShell() }
                    .keyboardShortcut("t", modifiers: [.command])
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
            }
        }
    }
}
