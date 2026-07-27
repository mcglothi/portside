import Foundation

/// A tab that was closed, kept with enough description to be listed in a menu.
///
/// The title is captured at close time rather than derived from the plan
/// afterwards, so a renamed tab comes back under the name it was closed under
/// instead of reverting to its host's name.
struct ClosedTab: Identifiable {
    let id = UUID()
    let plan: RestorePlan.TabPlan
    /// What the menu shows: the custom name if there was one, otherwise the
    /// active pane's own title.
    let title: String
    /// Kept apart from `title` so reopening restores a name the user chose but
    /// does not pin a host's live title as a custom one — that would stop the
    /// tab following the terminal as it changes.
    let customTitle: String?
    let paneCount: Int
    let closedAt: Date

    /// What the menu shows. Split tabs say so, because otherwise two entries a
    /// few minutes apart are indistinguishable by host name alone.
    var menuLabel: String {
        paneCount > 1 ? "\(title) — \(paneCount) panes" : title
    }
}

/// A bounded, most-recent-last ring of closed tabs.
///
/// Deliberately **in-memory only**, and not persisted with the workspace: this
/// is a record of what infrastructure someone had open, which is a different
/// proposition from the session restore that outlives a quit by design.
/// Quitting clears it.
///
/// Pure value semantics so the eviction and take-out rules test without a
/// `SessionManager`, a store, or a spawned terminal.
struct ClosedTabRing {
    private(set) var entries: [ClosedTab] = []
    let limit: Int

    init(limit: Int = 10) {
        self.limit = limit
    }

    var isEmpty: Bool { entries.isEmpty }

    /// Newest first — the order a menu lists them in, and the reverse of how
    /// they are stored.
    var mostRecentFirst: [ClosedTab] { entries.reversed() }

    mutating func record(_ tab: ClosedTab) {
        entries.append(tab)
        // A limit of zero means "keep nothing", so drop from the front until
        // the invariant holds rather than assuming one eviction is enough.
        while entries.count > limit {
            entries.removeFirst()
        }
    }

    /// Removes and returns a specific entry. Taking it out is the point: a tab
    /// that is open again is not a tab you can reopen.
    mutating func take(id: ClosedTab.ID) -> ClosedTab? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        return entries.remove(at: index)
    }

    mutating func takeMostRecent() -> ClosedTab? {
        entries.popLast()
    }

    mutating func clear() {
        entries.removeAll()
    }
}
