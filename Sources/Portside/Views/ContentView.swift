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
        .sheet(isPresented: $sessions.showQuickConnect) {
            QuickConnectView()
                .environmentObject(store)
                .environmentObject(sessions)
        }
    }
}
