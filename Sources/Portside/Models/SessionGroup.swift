import Foundation

/// A named set of hosts that reopens in the arrangement you left it in.
///
/// The request it comes from: eight Splunk boxes, saved in the sidebar as
/// "Splunk Servers", one click to get the whole grid back.
///
/// The layout is a `WorkspaceSnapshot.TabSnapshot` rather than anything new,
/// because that already models exactly this — a pane tree with orientations,
/// split fractions, per-leaf host-or-local-shell, and per-leaf MultiExec
/// membership — and the machinery that replays it on launch already exists and
/// is already tested. A group is a named one of those with a folder path.
struct SessionGroup: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    /// Same path convention as `SessionEntry.folder`, so groups sit in the
    /// tree beside the hosts they're made of.
    var folder: String = ""
    var isFavorite = false
    /// The pane tree to reopen: arrangement, split fractions, membership.
    ///
    /// Note what this deliberately does not carry: whether the tab was *armed*.
    /// `WorkspaceSnapshot` leaves that out so a relaunch never auto-broadcasts
    /// into freshly reconnected hosts, and a group is the same situation with
    /// the same answer — the group comes back assembled and disarmed. Arming
    /// stays a deliberate act.
    var layout: WorkspaceSnapshot.TabSnapshot
    /// Whether the group was saved from Grid View.
    var wasGridView = false
    /// Refreshed when the group's tab closes, so it remembers the arrangement
    /// you actually left rather than the one you first saved.
    var updatedAt = Date()

    /// Every library host the layout refers to, in pane order. Local shells
    /// have no entry and don't appear.
    var memberEntryIDs: [UUID] { Self.entryIDs(in: layout.root) }

    private static func entryIDs(in node: WorkspaceSnapshot.PaneSnapshot) -> [UUID] {
        switch node {
        case .leaf(let leaf):
            if case .host(let id) = leaf.kind { return [id] }
            return []
        case .split(_, let children):
            return children.flatMap { entryIDs(in: $0) }
        }
    }

    /// Total panes, including local shells — what the sidebar shows as the
    /// group's size, and what "opened 6 of 8" counts against.
    var paneCount: Int { Self.paneCount(in: layout.root) }

    private static func paneCount(in node: WorkspaceSnapshot.PaneSnapshot) -> Int {
        switch node {
        case .leaf: return 1
        case .split(_, let children): return children.reduce(0) { $0 + paneCount(in: $1) }
        }
    }
}

// Tolerant Codable, for the reason spelled out on `Macro`: the synthesized
// decoder ignores property defaults and throws on a missing key, so a field
// added here later would make one old group fail the *entire* library load.
// Written this way from the start rather than after being caught by it a third
// time.
extension SessionGroup {
    enum CodingKeys: String, CodingKey {
        case id, name, folder, isFavorite, layout, wasGridView, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        folder = try c.decodeIfPresent(String.self, forKey: .folder) ?? ""
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        // The one field with no sensible default: a group without a layout is
        // not a group. A decode failure here drops this group, and because
        // `Document.groups` is optional the rest of the library still loads.
        layout = try c.decode(WorkspaceSnapshot.TabSnapshot.self, forKey: .layout)
        wasGridView = try c.decodeIfPresent(Bool.self, forKey: .wasGridView) ?? false
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}
