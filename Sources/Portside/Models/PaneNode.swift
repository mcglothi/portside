import CoreGraphics
import Foundation

enum PaneOrientation: String, Codable { case horizontal, vertical }

/// Renormalizes split fractions to sum to 1 (after a child is added or removed).
func normalizedFractions(_ fractions: [CGFloat]) -> [CGFloat] {
    let total = fractions.reduce(0, +)
    guard total > 0 else {
        return Array(repeating: 1 / CGFloat(fractions.count), count: fractions.count)
    }
    return fractions.map { $0 / total }
}

/// A tab's terminal layout: a tree whose leaves are live sessions and whose
/// interior nodes are horizontal/vertical splits. Generic over the leaf type so
/// the tree algebra can be unit-tested with a lightweight stub; the app uses
/// `PaneNode<TerminalSession>`. See docs/split-panes-plan.md.
indirect enum PaneNode<Leaf: Identifiable>: Identifiable where Leaf.ID == UUID {
    case leaf(Leaf)
    case split(id: UUID, orientation: PaneOrientation, children: [PaneNode<Leaf>], fractions: [CGFloat])

    var id: UUID {
        switch self {
        case .leaf(let leaf): return leaf.id
        case .split(let id, _, _, _): return id
        }
    }

    /// Every leaf in this subtree, left-to-right / top-to-bottom.
    var leaves: [Leaf] {
        switch self {
        case .leaf(let leaf): return [leaf]
        case .split(_, _, let children, _): return children.flatMap(\.leaves)
        }
    }

    /// This subtree with `leafID` replaced by a two-way split of the old leaf
    /// and `newNode`, in the given orientation. Other nodes are untouched.
    func splitting(leafID: UUID, with newNode: PaneNode<Leaf>, orientation: PaneOrientation) -> PaneNode<Leaf> {
        switch self {
        case .leaf(let leaf):
            guard leaf.id == leafID else { return self }
            return .split(id: UUID(), orientation: orientation,
                          children: [self, newNode], fractions: [0.5, 0.5])
        case .split(let id, let o, let children, let fractions):
            return .split(id: id, orientation: o,
                          children: children.map {
                              $0.splitting(leafID: leafID, with: newNode, orientation: orientation)
                          },
                          fractions: fractions)
        }
    }

    /// This subtree with `leafID` swapped for `newLeaf` in place (same position
    /// and split geometry). Used to reconnect a dropped session's pane.
    func replacingLeaf(_ leafID: UUID, with newLeaf: Leaf) -> PaneNode<Leaf> {
        switch self {
        case .leaf(let leaf):
            return leaf.id == leafID ? .leaf(newLeaf) : self
        case .split(let id, let orientation, let children, let fractions):
            return .split(id: id, orientation: orientation,
                          children: children.map { $0.replacingLeaf(leafID, with: newLeaf) },
                          fractions: fractions)
        }
    }

    /// This subtree with the given leaf removed, collapsing any split that ends
    /// up with a single child. Returns nil when removing the leaf empties the
    /// subtree entirely (so the caller can drop the whole tab).
    func removingLeaf(_ leafID: UUID) -> PaneNode<Leaf>? {
        switch self {
        case .leaf(let leaf):
            return leaf.id == leafID ? nil : self
        case .split(let id, let orientation, let children, let fractions):
            var newChildren: [PaneNode<Leaf>] = []
            var newFractions: [CGFloat] = []
            for (child, fraction) in zip(children, fractions) {
                if let kept = child.removingLeaf(leafID) {
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
                              fractions: normalizedFractions(newFractions))
            }
        }
    }
}

/// One tab: a pane tree plus which leaf is focused. `broadcastArmed` is the
/// per-tab MultiExec state (used once MultiExec folds into the tree).
final class Tab: Identifiable, ObservableObject {
    let id = UUID()
    @Published var root: PaneNode<TerminalSession>
    @Published var activePaneID: UUID
    @Published var broadcastArmed = false
    /// When set, this tab shows only the named pane full-size (zoom/maximize),
    /// hiding the rest of the split until toggled off.
    @Published var zoomedPaneID: UUID?
    /// User-set tab name; falls back to the active leaf's title when nil.
    @Published var customTitle: String?

    init(session: TerminalSession) {
        root = .leaf(session)
        activePaneID = session.id
    }

    init(root: PaneNode<TerminalSession>, activePaneID: UUID) {
        self.root = root
        self.activePaneID = activePaneID
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
