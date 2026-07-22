import SwiftUI

/// Renders a tab's pane tree: leaves are terminals, interior nodes are
/// horizontal/vertical splits. Today every tab is a single leaf; this view is
/// already recursive so splitting (0.9) needs no new rendering code.
struct PaneTreeView: View {
    @ObservedObject var tab: Tab

    var body: some View {
        PaneNodeView(node: tab.root, tab: tab)
    }
}

struct PaneNodeView: View {
    let node: PaneNode<TerminalSession>
    @ObservedObject var tab: Tab

    var body: some View {
        switch node {
        case .leaf(let session):
            // Identity tied to the session so switching tabs (a single leaf,
            // not in a ForEach) recreates the terminal's NSViewRepresentable and
            // swaps to the new session's view — otherwise the cached NSView from
            // makeNSView keeps showing the previous session.
            PaneLeafView(session: session, tab: tab)
                .id(session.id)
        case .split(_, let orientation, let children, _):
            container(orientation, children)
        }
    }

    @ViewBuilder
    private func container(_ orientation: PaneOrientation, _ children: [PaneNode<TerminalSession>]) -> some View {
        // AnyView at the recursion point breaks the otherwise-infinite view type.
        if orientation == .horizontal {
            HSplitView {
                ForEach(children) { child in
                    AnyView(PaneNodeView(node: child, tab: tab))
                }
            }
        } else {
            VSplitView {
                ForEach(children) { child in
                    AnyView(PaneNodeView(node: child, tab: tab))
                }
            }
        }
    }
}

/// A single terminal leaf, plus the focus ring and — when its tab is armed for
/// MultiExec — a per-pane include toggle, protected-host guard, and the
/// included/excluded styling that used to live on the MultiExec grid tiles.
struct PaneLeafView: View {
    @EnvironmentObject var store: SessionStore
    @ObservedObject var session: TerminalSession
    @ObservedObject var tab: Tab
    @State private var confirmingInclude = false

    private var armed: Bool { tab.broadcastArmed }
    private var included: Bool { session.includedInMultiExec }
    private var isActive: Bool { tab.leaves.count > 1 && session.id == tab.activePaneID }
    private var alert: Color { Color(nsColor: store.appearance.alert) }

    var body: some View {
        TerminalPane(session: session)
            .opacity(armed && !included ? 0.55 : 1)
            .overlay(alignment: .topLeading) {
                if armed { includeChip.padding(6) }
            }
            .overlay {
                let ring = ringColor
                if ring != nil {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(ring!, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            .confirmationDialog(
                "\"\(session.title)\" is a protected host. Include it in the MultiExec broadcast?",
                isPresented: $confirmingInclude
            ) {
                Button("Include Protected Host", role: .destructive) {
                    session.includedInMultiExec = true
                }
                Button("Cancel", role: .cancel) {}
            }
    }

    /// Accent ring on the active pane; otherwise the alert-colored ring on an
    /// included pane while armed. Nil (no ring) for a lone or excluded pane.
    private var ringColor: Color? {
        if isActive { return .accentColor }
        if armed && included { return alert.opacity(0.8) }
        return nil
    }

    private var includeChip: some View {
        HStack(spacing: 4) {
            Image(systemName: included ? "checkmark.square.fill" : "square")
                .foregroundStyle(included ? alert : .secondary)
            if session.isProtected {
                Image(systemName: "lock.fill").foregroundStyle(.secondary)
            }
            Text(session.title).lineLimit(1)
        }
        .font(.caption)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.quaternary))
        .contentShape(Capsule())
        .onTapGesture(perform: toggleInclude)
        .help("Include this pane in the MultiExec broadcast")
    }

    private func toggleInclude() {
        if !included, session.isProtected {
            confirmingInclude = true
        } else {
            session.includedInMultiExec.toggle()
        }
    }
}
