import CoreGraphics
import Foundation

/// A tab's terminal layout: a tree whose leaves are live sessions and whose
/// interior nodes are horizontal/vertical splits. Today every tab is a single
/// leaf; split operations (0.9) grow the tree. See docs/split-panes-plan.md.
indirect enum PaneNode: Identifiable {
    case leaf(TerminalSession)
    case split(id: UUID, orientation: Orientation, children: [PaneNode], fractions: [CGFloat])

    enum Orientation { case horizontal, vertical }

    var id: UUID {
        switch self {
        case .leaf(let session): return session.id
        case .split(let id, _, _, _): return id
        }
    }

    /// Every session in this subtree, left-to-right / top-to-bottom.
    var leaves: [TerminalSession] {
        switch self {
        case .leaf(let session): return [session]
        case .split(_, _, let children, _): return children.flatMap(\.leaves)
        }
    }

    /// This subtree with the given leaf removed, collapsing any split that ends
    /// up with a single child. Returns nil when removing the leaf empties the
    /// subtree entirely (so the caller can drop the whole tab).
    func removingLeaf(_ sessionID: UUID) -> PaneNode? {
        switch self {
        case .leaf(let session):
            return session.id == sessionID ? nil : self
        case .split(let id, let orientation, let children, let fractions):
            var newChildren: [PaneNode] = []
            var newFractions: [CGFloat] = []
            for (child, fraction) in zip(children, fractions) {
                if let kept = child.removingLeaf(sessionID) {
                    newChildren.append(kept)
                    newFractions.append(fraction)
                }
            }
            switch newChildren.count {
            case 0: return nil
            case 1: return newChildren[0]   // collapse a now-single-child split
            default:
                return .split(id: id, orientation: orientation,
                              children: newChildren,
                              fractions: normalized(newFractions))
            }
        }
    }
}

/// Renormalizes split fractions to sum to 1 after a child is removed.
private func normalized(_ fractions: [CGFloat]) -> [CGFloat] {
    let total = fractions.reduce(0, +)
    guard total > 0 else {
        return Array(repeating: 1 / CGFloat(fractions.count), count: fractions.count)
    }
    return fractions.map { $0 / total }
}

/// One tab: a pane tree plus which leaf is focused. `broadcastArmed` is the
/// per-tab MultiExec state (used once MultiExec folds into the tree).
final class Tab: Identifiable, ObservableObject {
    let id = UUID()
    @Published var root: PaneNode
    @Published var activePaneID: UUID
    @Published var broadcastArmed = false

    init(session: TerminalSession) {
        root = .leaf(session)
        activePaneID = session.id
    }

    var leaves: [TerminalSession] { root.leaves }

    /// The focused leaf, falling back to the first if the active id is stale.
    var activeLeaf: TerminalSession? {
        leaves.first { $0.id == activePaneID } ?? leaves.first
    }

    func contains(_ sessionID: UUID) -> Bool {
        leaves.contains { $0.id == sessionID }
    }
}
