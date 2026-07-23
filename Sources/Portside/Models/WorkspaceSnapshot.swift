import CoreGraphics
import Foundation

/// A snapshot of the open session layout — the tabs, each tab's pane tree, and
/// which tab was active — so the workspace can be reopened on the next launch.
/// Persisted in the library Document.
///
/// Deliberately does NOT store which tab was armed for MultiExec: restore
/// reopens the layout but always launches disarmed, so a relaunch never
/// auto-broadcasts into freshly reconnected hosts. See docs/split-panes-plan.md.
struct WorkspaceSnapshot: Codable, Equatable {
    var tabs: [TabSnapshot] = []
    /// Position (not id) of the tab that was active — replay mints new ids.
    var selectedTabIndex: Int?
    /// Whether Grid View was on when this was saved. Grid View collapses every
    /// tab into one big split tree, which on its own looks indistinguishable
    /// from an ordinary multi-pane tab — without this, restore had no way to
    /// know the Grid View toggle should come back on, leaving it stuck (can't
    /// turn on: only one tab exists; can't turn off: the manager doesn't think
    /// it's in Grid View).
    var wasGridView: Bool = false

    struct TabSnapshot: Codable, Equatable {
        var root: PaneSnapshot
    }

    /// A tab's pane tree, mirroring `PaneNode` but with restore-stable payloads.
    indirect enum PaneSnapshot: Codable, Equatable {
        case leaf(Leaf)
        case split(orientation: PaneOrientation, children: [PaneSnapshot], fractions: [CGFloat])
    }

    /// A single pane: a library host (by entry id) or an entry-less local shell,
    /// plus its MultiExec membership.
    struct Leaf: Codable, Equatable {
        enum Kind: Codable, Equatable {
            case host(UUID)
            case localShell
        }
        var kind: Kind
        var includedInMultiExec: Bool
    }

    var isEmpty: Bool { tabs.isEmpty }

    // Custom coding so old flat snapshots (a list of `items` = single-pane tabs)
    // still decode; new snapshots always write the tree form.
    private enum CodingKeys: String, CodingKey {
        case tabs, selectedTabIndex, items, selectedIndex, wasGridView
    }

    init(tabs: [TabSnapshot] = [], selectedTabIndex: Int? = nil, wasGridView: Bool = false) {
        self.tabs = tabs
        self.selectedTabIndex = selectedTabIndex
        self.wasGridView = wasGridView
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let tabs = try c.decodeIfPresent([TabSnapshot].self, forKey: .tabs) {
            self.tabs = tabs
            self.selectedTabIndex = try c.decodeIfPresent(Int.self, forKey: .selectedTabIndex)
        } else if let items = try c.decodeIfPresent([Leaf].self, forKey: .items) {
            // v1 flat form: each item becomes a single-leaf tab.
            self.tabs = items.map { TabSnapshot(root: .leaf($0)) }
            self.selectedTabIndex = try c.decodeIfPresent(Int.self, forKey: .selectedIndex)
        } else {
            self.tabs = []
            self.selectedTabIndex = nil
        }
        self.wasGridView = try c.decodeIfPresent(Bool.self, forKey: .wasGridView) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tabs, forKey: .tabs)
        try c.encodeIfPresent(selectedTabIndex, forKey: .selectedTabIndex)
        try c.encode(wasGridView, forKey: .wasGridView)
    }
}

/// What replay should do for one pane, resolved against the current library.
enum RestoreAction: Equatable {
    case connect(SessionEntry, includedInMultiExec: Bool)
    case localShell(includedInMultiExec: Bool)
}

/// A restore plan: the tabs to rebuild (each a tree of actions) and which tab to
/// select. Pure data so the planner is unit-testable without spawning terminals.
struct RestorePlan: Equatable {
    var tabs: [TabPlan] = []
    var selectedTabIndex: Int?
    var wasGridView: Bool = false

    struct TabPlan: Equatable { var root: PanePlan }

    indirect enum PanePlan: Equatable {
        case leaf(RestoreAction)
        case split(orientation: PaneOrientation, children: [PanePlan], fractions: [CGFloat])

        var leafCount: Int {
            switch self {
            case .leaf: return 1
            case .split(_, let children, _): return children.reduce(0) { $0 + $1.leafCount }
            }
        }
    }

    /// Total panes across all tabs — for the "Reopen N sessions?" prompt.
    var paneCount: Int { tabs.reduce(0) { $0 + $1.root.leafCount } }
}

extension WorkspaceSnapshot {
    /// Resolves the snapshot against the current library into a restore plan,
    /// dropping panes whose host was deleted (and collapsing / dropping the
    /// splits and tabs that empties), and remapping the selected tab.
    func plan(entryForID: (UUID) -> SessionEntry?) -> RestorePlan {
        var tabPlans: [RestorePlan.TabPlan] = []
        var selected: Int?
        for (index, tab) in tabs.enumerated() {
            guard let root = Self.resolve(tab.root, entryForID) else { continue }
            if index == selectedTabIndex { selected = tabPlans.count }
            tabPlans.append(RestorePlan.TabPlan(root: root))
        }
        return RestorePlan(tabs: tabPlans, selectedTabIndex: selected, wasGridView: wasGridView)
    }

    private static func resolve(_ node: PaneSnapshot,
                                _ entryForID: (UUID) -> SessionEntry?) -> RestorePlan.PanePlan? {
        switch node {
        case .leaf(let leaf):
            switch leaf.kind {
            case .host(let id):
                return entryForID(id).map { .leaf(.connect($0, includedInMultiExec: leaf.includedInMultiExec)) }
            case .localShell:
                return .leaf(.localShell(includedInMultiExec: leaf.includedInMultiExec))
            }
        case .split(let orientation, let children, let fractions):
            var kept: [RestorePlan.PanePlan] = []
            var keptFractions: [CGFloat] = []
            for (child, fraction) in zip(children, fractions) {
                if let resolved = resolve(child, entryForID) {
                    kept.append(resolved)
                    keptFractions.append(fraction)
                }
            }
            switch kept.count {
            case 0: return nil
            case 1: return kept[0]   // collapse a now-single-child split
            default: return .split(orientation: orientation, children: kept,
                                   fractions: normalizedFractions(keptFractions))
            }
        }
    }
}
