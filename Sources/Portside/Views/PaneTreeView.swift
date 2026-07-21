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
    let node: PaneNode
    @ObservedObject var tab: Tab

    var body: some View {
        switch node {
        case .leaf(let session):
            TerminalPane(session: session)
                .overlay(activeRing(for: session))
        case .split(_, let orientation, let children, _):
            container(orientation, children)
        }
    }

    @ViewBuilder
    private func container(_ orientation: PaneNode.Orientation, _ children: [PaneNode]) -> some View {
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

    /// A focus ring on the active pane — only meaningful once a tab has more
    /// than one pane, so a lone terminal looks exactly as it does today.
    @ViewBuilder
    private func activeRing(for session: TerminalSession) -> some View {
        if tab.leaves.count > 1 && session.id == tab.activePaneID {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .allowsHitTesting(false)
        }
    }
}
