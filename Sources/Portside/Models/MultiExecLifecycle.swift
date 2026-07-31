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
    case paneReconnected(host: String)
    /// The machine slept. Everything on the other side of every connection had
    /// an unbounded amount of time to change while nobody was watching.
    case systemWoke

    var message: String {
        switch self {
        case .paneReconnected(let host):
            return "MultiExec disarmed — \(host) reconnected. Its shell is fresh, "
                 + "so the group is no longer in a known matching state."
        case .systemWoke:
            return "MultiExec disarmed — the Mac slept. Re-arm once you've "
                 + "confirmed the sessions are still where you left them."
        }
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
