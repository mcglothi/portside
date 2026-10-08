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
        .modifier(AgentPrompts())
        // Unconditional, with the indicator hiding itself, so ContentView needn't
        // observe Agent Access just to decide whether the item exists.
        .toolbar {
            ToolbarItem(placement: .primaryAction) { AgentIndicator() }
        }
    }

    private var restorePrompt: String {
        let n = sessions.pendingRestore?.paneCount ?? 0
        return "Reopen \(n) session\(n == 1 ? "" : "s") from last time?"
    }
}

/// Agent Access's alert and log sheet, kept out of `ContentView`'s own body.
///
/// So that the window's root view doesn't observe the controller: every agent
/// change — each request logged — would otherwise re-render all of it.
private struct AgentPrompts: ViewModifier {
    @EnvironmentObject var agent: AgentController

    /// A program asking, through Agent Access, for something a person has to
    /// OK. Answered here and only here — never over the socket.
    ///
    /// Dismissal answers nothing by itself: every way out of the alert is one
    /// of its buttons, and Escape is the refusal. Answering nil here ran
    /// *after* a button's own answer, and with a second prompt queued it
    /// refused that one before anyone saw it.
    private var promptShown: Binding<Bool> {
        Binding(get: { agent.prompt != nil }, set: { _ in })
    }

    func body(content: Content) -> some View {
        content
            .alert(agent.prompt?.title ?? "", isPresented: promptShown, presenting: agent.prompt) { prompt in
                // The refusal is the default *and* the cancel action, so
                // neither Return nor Escape can approve anything.
                ForEach(Array(prompt.choices.enumerated()), id: \.offset) { index, choice in
                    if index == prompt.refusal {
                        Button(choice, role: .cancel) { agent.answer(index) }
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button(choice) { agent.answer(index) }
                    }
                }
            } message: { prompt in
                Text(prompt.message)
            }
            .sheet(isPresented: $agent.showingLog) { AgentLogView().environmentObject(agent) }
    }
}
