import Foundation

/// A bulk edit to which panes MultiExec broadcasts into.
///
/// Kept as a pure function over `(included, isProtected)` rather than a method
/// on `SessionManager` so the protected-host rule is testable without spawning
/// terminal sessions — every `TerminalSession` init starts a real process, port,
/// or fd.
/// Where focus should land after a bulk action changes pane membership.
///
/// Typing into an excluded pane still reaches that pane — deliberate, and worth
/// keeping: it's how you run a one-off on the host you just took out. The
/// hazard is having it happen *without asking*. A bulk action can pull the
/// broadcast out from under the focused pane, and nothing about the caret says
/// so, so the next command silently hits one host instead of the group.
enum MultiExecFocus {
    /// The pane that should take focus, or nil to leave it where it is.
    ///
    /// Nil when the focused pane is still in the broadcast (nothing to fix) and
    /// when nothing is included at all (Exclude All has nowhere better to go,
    /// and a 0-of-N banner is its own warning).
    static func refocused(from focused: UUID?,
                          panes: [(id: UUID, included: Bool)]) -> UUID? {
        guard let focused,
              let current = panes.first(where: { $0.id == focused }),
              !current.included,
              let firstIncluded = panes.first(where: \.included)
        else { return nil }
        return firstIncluded.id
    }
}

enum MultiExecBulkAction: CaseIterable {
    case includeAll, excludeAll, invert

    /// One name per action, shared by the armed banner's buttons and the
    /// View ▸ MultiExec Panes menu items, so the two can't drift apart.
    var label: String {
        switch self {
        case .includeAll: return "Include All"
        case .excludeAll: return "Exclude All"
        case .invert: return "Invert Selection"
        }
    }

    /// The rebindable shortcut that runs this action.
    var shortcutAction: ShortcutAction {
        switch self {
        case .includeAll: return .includeAllPanes
        case .excludeAll: return .excludeAllPanes
        case .invert: return .invertPaneSelection
        }
    }

    var help: String {
        switch self {
        case .includeAll: return "Put every pane back in the broadcast (protected hosts stay out)"
        case .excludeAll: return "Drop every pane out of the broadcast"
        case .invert: return "Swap which panes are included (protected hosts stay out)"
        }
    }

    /// The new inclusion state for one pane.
    ///
    /// A bulk action never sweeps a protected host *in* — those only join the
    /// broadcast through the per-pane confirmation, which is the whole point of
    /// marking a host protected. Sweeping one *out* is always allowed, so
    /// "Exclude All" is a reliable panic button.
    func applied(included: Bool, isProtected: Bool) -> Bool {
        switch self {
        case .includeAll: return isProtected ? included : true
        case .excludeAll: return false
        case .invert: return included ? false : !isProtected
        }
    }
}
