import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var sessions: SessionManager

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            SessionArea()
        }
        // Presented here rather than on a pane: it is also reachable from the
        // sidebar, for a host that isn't connected yet.
        .sheet(item: $sessions.explainingEntry) { entry in
            ConnectionExplanationSheet(entry: entry)
                .environmentObject(store)
                .environmentObject(sessions)
        }
        .sheet(isPresented: $sessions.showQuickConnect) {
            QuickConnectView()
                .environmentObject(store)
                .environmentObject(sessions)
        }
        .confirmationDialog(
            restorePrompt,
            isPresented: Binding(
                get: { sessions.pendingRestore != nil },
                set: { if !$0 { sessions.pendingRestore = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Restore") {
                if let plan = sessions.pendingRestore { sessions.restore(plan) }
                sessions.pendingRestore = nil
            }
            Button("Start Fresh", role: .cancel) { sessions.pendingRestore = nil }
        }
    }

    private var restorePrompt: String {
        let n = sessions.pendingRestore?.paneCount ?? 0
        return "Reopen \(n) session\(n == 1 ? "" : "s") from last time?"
    }
}
