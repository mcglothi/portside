import Foundation

/// Why an armed broadcast was taken down without the user asking.
///
/// Arming is a deliberate act, so disarming behind the user's back needs a
/// reason good enough to state plainly — the banner disappearing is the signal
/// that something changed, and it has to be followed by *what*. Anything that
/// can't fill in this sentence isn't a good enough reason to disarm.
enum MultiExecDisarmReason: Equatable {
    /// A pane's session was relaunched. The replacement is a fresh shell that
    /// may be at a login prompt, in a different directory, or — if DNS or a
    /// jump host moved underneath it — on a different machine entirely.
    /// `host` is nil for a session with no library entry — a local shell.
    /// Its title is whatever the shell last reported through OSC, which after
    /// an `exit` is the literal word "exit", so naming it would produce
    /// "exit reconnected".
    case paneReconnected(host: String?)
    /// The Mac changed network. A jump host or ProxyJump chain can resolve
    /// somewhere else than it did when the group was armed — coming off a VPN,
    /// or moving between office and home Wi-Fi, leaves `prod-db` pointing at a
    /// different machine while the panes look untouched, because established
    /// connections survive the change and only new ones follow the new route.
    case networkChanged
    /// The machine slept. Everything on the other side of every connection had
    /// an unbounded amount of time to change while nobody was watching.
    case systemWoke

    var message: String {
        switch self {
        case .paneReconnected(let host):
            let who = host.map { "\($0) reconnected" } ?? "a pane reconnected"
            return "MultiExec disarmed — \(who). Its shell is fresh, "
                 + "so the group is no longer in a known matching state."
        case .networkChanged:
            return "MultiExec disarmed — the network changed. Host names can "
                 + "resolve somewhere else from here, so check the group still "
                 + "points where you think before re-arming."
        case .systemWoke:
            return "MultiExec disarmed — the Mac slept. Re-arm once you've "
                 + "confirmed the sessions are still where you left them."
        }
    }
}

/// Whether a new network path is a real change or ordinary churn.
///
/// `NWPathMonitor` fires for a great deal that isn't interesting: every
/// transition through `.unsatisfied` and back as an interface renegotiates,
/// every change in the expensive/constrained flags. A guardrail that fires
/// during ordinary work is one people learn to route around, so this keys on
/// the set of interfaces actually carrying traffic and nothing else.
enum NetworkChangeDecision {
    /// - Parameters:
    ///   - previous: interfaces from the last path, nil before the first one.
    ///   - current: interfaces from the path just reported.
    ///   - satisfied: whether the new path can actually carry traffic.
    static func shouldDisarm(previous: Set<String>?, current: Set<String>, satisfied: Bool) -> Bool {
        // The first callback establishes the baseline; there is nothing to
        // have changed *from* yet, and disarming on it would take the group
        // down every launch.
        guard let previous else { return false }
        // A path that can't carry traffic isn't a move to somewhere else, it's
        // a gap — usually a moment long, on the way to the same place. Waiting
        // for it to settle avoids disarming on every brief drop.
        guard satisfied else { return false }
        return current != previous
    }
}

/// Whether a paste into an armed broadcast should be confirmed first.
///
/// Typing is self-limiting: a mistake is one keystroke wide and you watch it
/// land. Paste is not — the whole point of it is that a lot of input arrives
/// at once, already committed, and under MultiExec it arrives on every
/// included host simultaneously. This is the one input path where the gap
/// between "what I meant" and "what ran" can be arbitrarily large.
enum BroadcastPasteReview: Equatable {
    /// Send it. Either not broadcasting, or small and single-command.
    case send
    /// Confirm first, showing this much of what's about to run.
    case confirm(lineCount: Int, characterCount: Int)

    /// A paste longer than this is worth a look regardless of shape — a wall
    /// of base64 or a stray file's contents is not something anyone means to
    /// run on twelve hosts at once.
    static let largePasteThreshold = 512

    /// - Parameters:
    ///   - text: the clipboard contents about to be sent.
    ///   - targetCount: how many panes it will reach, focused pane included.
    static func review(text: String, targetCount: Int) -> BroadcastPasteReview {
        // One pane is the operator's own session and their own business; the
        // hazard here is specifically fan-out.
        guard targetCount > 1 else { return .send }

        // A single trailing newline is the ordinary "run this one command"
        // paste and must not nag — it's the shape of every useful paste.
        // Interior newlines mean several commands, which is the case where
        // a half-read clipboard does real damage.
        let trimmed = text.hasSuffix("\n") ? String(text.dropLast()) : text
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        let isMultiCommand = lines.count > 1
        let isLarge = text.count > largePasteThreshold

        guard isMultiCommand || isLarge else { return .send }
        return .confirm(lineCount: lines.count, characterCount: text.count)
    }
}
