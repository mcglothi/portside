import Foundation

/// A snapshot of the open session layout — which tabs, in what order, which was
/// active, and each tab's MultiExec membership — so the workspace can be
/// reopened on the next launch. Persisted in the library Document.
///
/// Deliberately does NOT store `multiExecActive`: restore reopens the group but
/// always launches disarmed, so a relaunch never auto-broadcasts keystrokes
/// into freshly reconnected hosts. See docs/session-restore-plan.md.
struct WorkspaceSnapshot: Codable, Equatable {
    var items: [Item] = []
    /// Position (not id) of the tab that was active — replay mints new ids.
    var selectedIndex: Int?

    struct Item: Codable, Equatable {
        /// A library host (by entry id) or an entry-less local shell.
        enum Kind: Codable, Equatable {
            case host(UUID)
            case localShell
        }
        var kind: Kind
        var includedInMultiExec: Bool
    }

    var isEmpty: Bool { items.isEmpty }
}

/// What replay should actually do, resolved against the current library. Pure
/// data so the planner can be unit-tested without spawning terminals.
enum RestoreAction: Equatable {
    case connect(SessionEntry, includedInMultiExec: Bool)
    case localShell(includedInMultiExec: Bool)
}

struct RestorePlan: Equatable {
    var actions: [RestoreAction] = []
    /// Index into `actions` of the tab to select, once created. Nil when the
    /// previously selected tab didn't survive (e.g. its host was deleted).
    var selectedActionIndex: Int?
}

extension WorkspaceSnapshot {
    /// Turns a snapshot into an ordered action list, resolving hosts against the
    /// current library and dropping any whose entry was deleted. Selection is
    /// remapped to the surviving tab's new position.
    func plan(entryForID: (UUID) -> SessionEntry?) -> RestorePlan {
        var actions: [RestoreAction] = []
        var selectedActionIndex: Int?

        for (originalIndex, item) in items.enumerated() {
            let action: RestoreAction?
            switch item.kind {
            case .host(let id):
                action = entryForID(id).map { .connect($0, includedInMultiExec: item.includedInMultiExec) }
            case .localShell:
                action = .localShell(includedInMultiExec: item.includedInMultiExec)
            }
            guard let action else { continue } // deleted host — skip
            if originalIndex == selectedIndex {
                selectedActionIndex = actions.count
            }
            actions.append(action)
        }

        return RestorePlan(actions: actions, selectedActionIndex: selectedActionIndex)
    }
}
