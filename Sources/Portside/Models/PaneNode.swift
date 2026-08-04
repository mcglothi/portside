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

    /// This subtree with the panes `a` and `b` exchanged, each taking the
    /// other's position and split geometry.
    ///
    /// Swap rather than insert, deliberately. A grid is a seating chart, not a
    /// list: reflowing on insert would shift every pane after the target, so one
    /// drag visibly rearranges most of the screen. Exchanging two panes moves
    /// exactly the two things you pointed at — and it stays defined on
    /// hand-split layouts, where "insert between these two" has no unambiguous
    /// answer but "these two trade places" always does.
    ///
    /// **A split whose children changed places gets a fresh id.** That is not
    /// bookkeeping — it is the whole difference between this working and
    /// crashing. `HSplitView` cannot survive having its arranged subviews
    /// reordered underneath it: AppKit throws from
    /// `_postWindowNeedsUpdateConstraints` mid-layout, and short of that the
    /// divider positions come out wrong, leaving one pane a sliver and the
    /// other enormous. A new id makes SwiftUI discard that split and build a
    /// fresh one in the new order, which divides evenly as splits are meant to.
    ///
    /// Returns self unchanged when either id isn't a leaf here, or when they're
    /// the same pane, so a drop on itself is a no-op rather than a rebuild.
    func swappingLeaves(_ a: UUID, _ b: UUID) -> PaneNode<Leaf> {
        guard a != b else { return self }
        let all = leaves
        guard let leafA = all.first(where: { $0.id == a }),
              let leafB = all.first(where: { $0.id == b }) else { return self }
        return exchanging(a, for: leafB, and: b, for: leafA).node
    }

    /// One pass, rather than two `replacingLeaf` calls: after replacing `a` with
    /// b's leaf the tree briefly holds two leaves whose id is `b`, and the
    /// second replacement would overwrite both — the same session in two cells
    /// and the other one gone.
    ///
    /// Reports whether anything beneath changed, because **a new id has to
    /// propagate all the way to the root**. Giving a split a fresh id changes
    /// its *parent's* child identities, which is the same arranged-subview
    /// mutation one level up — so an ancestor that kept its id would be left
    /// rearranging a live split view, which is the bug this was meant to fix.
    ///
    /// The first version of this only checked whether a direct child *was* one
    /// of the swapped leaves. That is right for a single split and wrong for
    /// anything taller: a five-pane grid is a vertical split over rows, and
    /// swapping within a row rebuilt the row but left the root reordering its
    /// two children — the horizontal resize became a vertical one.
    private func exchanging(_ a: UUID, for leafB: Leaf,
                            and b: UUID, for leafA: Leaf) -> (node: PaneNode<Leaf>, changed: Bool) {
        switch self {
        case .leaf(let leaf):
            if leaf.id == a { return (.leaf(leafB), true) }
            if leaf.id == b { return (.leaf(leafA), true) }
            return (self, false)
        case .split(let id, let orientation, let children):
            let results = children.map { $0.exchanging(a, for: leafB, and: b, for: leafA) }
            let changed = results.contains(where: \.changed)
            return (.split(id: changed ? UUID() : id,
                           orientation: orientation,
                           children: results.map(\.node)),
                    changed)
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
    /// Why *this tab* disarmed itself, if it did.
    ///
    /// Per-tab rather than app-wide: it used to live on the manager, so
    /// disarming one tab put the notice on every tab — including ones that
    /// were never armed, which reads as the app announcing something that
    /// didn't happen to you.
    @Published var disarmNotice: MultiExecDisarmReason?

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
