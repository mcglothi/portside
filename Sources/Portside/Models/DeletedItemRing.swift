import Foundation

/// One delete the user can take back, whatever it removed.
///
/// A single batch rather than one record per row because deletes arrive as a
/// selection: taking back "delete 4 hosts and a group" has to restore all five
/// or it hasn't undone what happened.
struct DeletedItems: Identifiable {
    let id = UUID()
    var hosts: [SessionEntry] = []
    var groups: [SessionGroup] = []
    var macros: [Macro] = []
    let deletedAt: Date

    init(hosts: [SessionEntry] = [], groups: [SessionGroup] = [], macros: [Macro] = [],
         deletedAt: Date = Date()) {
        self.hosts = hosts
        self.groups = groups
        self.macros = macros
        self.deletedAt = deletedAt
    }

    var count: Int { hosts.count + groups.count + macros.count }
    var isEmpty: Bool { count == 0 }

    /// Names what would come back, since a menu item reading "Undo Delete" tells
    /// you nothing about which delete you are about to reverse.
    var menuLabel: String {
        if count == 1 {
            return hosts.first?.name ?? groups.first?.name ?? macros.first?.name ?? "1 item"
        }
        let parts = [
            hosts.isEmpty ? nil : "\(hosts.count) host\(hosts.count == 1 ? "" : "s")",
            groups.isEmpty ? nil : "\(groups.count) group\(groups.count == 1 ? "" : "s")",
            macros.isEmpty ? nil : "\(macros.count) macro\(macros.count == 1 ? "" : "s")",
        ].compactMap { $0 }
        return parts.joined(separator: " and ")
    }
}

/// A bounded, most-recent-last ring of deletions.
///
/// In-memory only, like `ClosedTabRing` and for the same reason: this holds a
/// copy of hosts someone deleted, which is not something to leave lying in a
/// file after they asked for it to be gone. Quitting drops it.
///
/// The ring's depth is also a *deadline*. A deleted host's Keychain password
/// isn't removed while the delete can still be taken back — undo has to restore
/// a host that can still authenticate, and stashing the plaintext somewhere to
/// put back later would move a secret out of the Keychain, which is exactly
/// where it belongs. So `record` hands back whatever it evicted: those are the
/// deletes that just became permanent, and their passwords go with them.
///
/// Pure value semantics, so eviction and take-out test without a store.
struct DeletedItemRing {
    private(set) var entries: [DeletedItems] = []
    let limit: Int

    init(limit: Int = 10) {
        self.limit = limit
    }

    var isEmpty: Bool { entries.isEmpty }

    /// Newest first — menu order, the reverse of how they're stored.
    var mostRecentFirst: [DeletedItems] { entries.reversed() }

    var mostRecent: DeletedItems? { entries.last }

    /// Records a deletion and returns the batches pushed out of the ring, which
    /// the caller must treat as permanent. Never records an empty batch: a
    /// delete that removed nothing is not one worth offering to undo, and it
    /// would push a real one out.
    @discardableResult
    mutating func record(_ batch: DeletedItems) -> [DeletedItems] {
        guard !batch.isEmpty else { return [] }
        entries.append(batch)
        var evicted: [DeletedItems] = []
        // A limit of zero means "keep nothing", so drop from the front until the
        // invariant holds rather than assuming one eviction is enough.
        while entries.count > limit {
            evicted.append(entries.removeFirst())
        }
        return evicted
    }

    /// Removes and returns a specific batch. Taking it out is the point: a host
    /// that is back in the library is not one you can restore again.
    mutating func take(id: DeletedItems.ID) -> DeletedItems? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        return entries.remove(at: index)
    }

    mutating func takeMostRecent() -> DeletedItems? {
        entries.popLast()
    }

    /// Empties the ring and returns everything in it, so a caller shutting down
    /// can finish the deletions the ring was holding open.
    mutating func drain() -> [DeletedItems] {
        defer { entries.removeAll() }
        return entries
    }
}
