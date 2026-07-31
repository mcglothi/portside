import CoreGraphics
import Foundation

enum PaneOrientation: String, Codable { case horizontal, vertical }

/// A tab's terminal layout: a tree whose leaves are live sessions and whose
/// interior nodes are horizontal/vertical splits. Generic over the leaf type so
/// the tree algebra can be unit-tested with a lightweight stub; the app uses
/// `PaneNode<TerminalSession>`. See docs/split-panes-plan.md.
indirect enum PaneNode<Leaf: Identifiable>: Identifiable where Leaf.ID == UUID {
    case leaf(Leaf)
    // No proportions here, deliberately. A `fractions` array lived on this
    // case for a long time: persisted, round-tripped, and tested — and never
    // once set from anything a user did. Nothing observed a divider drag
    // (HSplitView doesn't report positions), so it only ever held 0.5/0.5 or
    // an even split, and the renderer discarded it anyway. Storing a layout
    // the app can neither capture nor honour promised something it never did.
    //
    // Splits open evenly. Making them remember a hand-dragged size needs a
    // splitter that both reports and accepts positions — an NSSplitView bridge
    // or a custom SwiftUI one — at which point the value comes back with a
    // real source and a real consumer.
    case split(id: UUID, orientation: PaneOrientation, children: [PaneNode<Leaf>])

    var id: UUID {
        switch self {
        case .leaf(let leaf): return leaf.id
        case .split(let id, _, _): return id
        }
    }

    /// Every leaf in this subtree, left-to-right / top-to-bottom.
    var leaves: [Leaf] {
        switch self {
        case .leaf(let leaf): return [leaf]
        case .split(_, _, let children): return children.flatMap(\.leaves)
        }
    }

    /// This subtree with `leafID` replaced by a two-way split of the old leaf
    /// and `newNode`, in the given orientation. Other nodes are untouched.
    func splitting(leafID: UUID, with newNode: PaneNode<Leaf>, orientation: PaneOrientation) -> PaneNode<Leaf> {
        switch self {
        case .leaf(let leaf):
            guard leaf.id == leafID else { return self }
            return .split(id: UUID(), orientation: orientation,
                          children: [self, newNode])
        case .split(let id, let o, let children):
            return .split(id: id, orientation: o,
                          children: children.map {
                              $0.splitting(leafID: leafID, with: newNode, orientation: orientation)
                          })
        }
    }

    /// This subtree with `leafID` swapped for `newLeaf` in place (same position
    /// and split geometry). Used to reconnect a dropped session's pane.
    func replacingLeaf(_ leafID: UUID, with newLeaf: Leaf) -> PaneNode<Leaf> {
        switch self {
        case .leaf(let leaf):
            return leaf.id == leafID ? .leaf(newLeaf) : self
        case .split(let id, let orientation, let children):
            return .split(id: id, orientation: orientation,
                          children: children.map { $0.replacingLeaf(leafID, with: newLeaf) })
        }
    }

    /// This subtree with the given leaf removed, collapsing any split that ends
    /// up with a single child. Returns nil when removing the leaf empties the
    /// subtree entirely (so the caller can drop the whole tab).
    func removingLeaf(_ leafID: UUID) -> PaneNode<Leaf>? {
        switch self {
        case .leaf(let leaf):
            return leaf.id == leafID ? nil : self
        case .split(let id, let orientation, let children):
            let newChildren = children.compactMap { $0.removingLeaf(leafID) }
            switch newChildren.count {
            case 0: return nil
            case 1: return newChildren[0]   // collapse a now-single-child split
            default:
                return .split(id: id, orientation: orientation, children: newChildren)
            }
        }
    }
}

/// One tab: a pane tree plus which leaf is focused. `broadcastArmed` is the
/// per-tab MultiExec state (used once MultiExec folds into the tree).
///
/// `root`/`activePaneID` are optional so a tab can exist with no session yet
/// (the start-page tab opened by the tab bar's + button) — every other tab
/// kind always has both set together. See `isStartPage`.
final class Tab: Identifiable, ObservableObject {
    let id = UUID()
    @Published var root: PaneNode<TerminalSession>?
    @Published var activePaneID: UUID?
    @Published var broadcastArmed = false
    /// When set, this tab shows only the named pane full-size (zoom/maximize),
    /// hiding the rest of the split until toggled off.
    @Published var zoomedPaneID: UUID?
    /// User-set tab name; falls back to the active leaf's title when nil.
    @Published var customTitle: String?
    /// The saved group this tab was opened from, if any. Set so closing the
    /// tab can write the arrangement back to that group.
    var groupID: UUID?

    init(session: TerminalSession) {
        root = .leaf(session)
        activePaneID = session.id
    }

    init(root: PaneNode<TerminalSession>, activePaneID: UUID) {
        self.root = root
        self.activePaneID = activePaneID
    }

    /// A blank "welcome aboard" tab with no live session — the tab bar's +
    /// button opens one of these instead of a local shell; selecting a host or
    /// starting a local shell from it morphs this same tab in place.
    private init() {
        root = nil
        activePaneID = nil
    }

    static func startPage() -> Tab { Tab() }

    var isStartPage: Bool { root == nil }

    var leaves: [TerminalSession] { root?.leaves ?? [] }

    /// The focused leaf, falling back to the first if the active id is stale.
    var activeLeaf: TerminalSession? {
        leaves.first { $0.id == activePaneID } ?? leaves.first
    }

    func contains(_ sessionID: UUID) -> Bool {
        leaves.contains { $0.id == sessionID }
    }
}
