import Foundation

/// The same shell integration `ShellIntegrationSnippet` appends to a host's
/// `.bashrc`/`.zshrc`, rearranged so it can be *typed at a live prompt* instead
/// — the host reports its working directory for as long as the session lasts
/// and nothing on the remote filesystem is touched.
///
/// The point is the trade, not the mechanism. A persistent install survives
/// `exec`, `su`, a nested shell and every future session; an injected one does
/// not, and has to be re-sent per session. What it buys is that Portside stops
/// needing write access to someone's dotfiles to make the SFTP pane follow
/// `cd` — which on a shared or hardened box is the difference between the
/// feature working and the feature being declined.
///
/// **This is deliberately not a second dialect of the snippet.** The payload is
/// derived from `ShellIntegrationSnippet.text` at runtime rather than written
/// out again here, because the two forms drifting apart is exactly the failure
/// the v2/v3 comments in that file are a monument to. The only transformation
/// is dropping comment-only lines, which is mechanical and cannot change what
/// the shell does — as opposed to collapsing newlines into `;`, which is not
/// safe inside `case`/function bodies and is why this goes over the wire
/// base64-encoded with its line structure intact.
enum ShellIntegrationInjection {

    /// The snippet minus comment-only lines and blank lines.
    ///
    /// Only lines whose first non-space character is `#` are dropped, so a `#`
    /// appearing inside a string or parameter expansion is untouched. The
    /// version marker goes with them: it exists for the rc-file installer's
    /// `grep`, and there is no file to grep here.
    static func payload(for snippet: ShellIntegrationSnippet) -> String {
        snippet.text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter {
                let trimmed = $0.trimmingCharacters(in: .whitespaces)
                return !trimmed.isEmpty && !trimmed.hasPrefix("#")
            }
            .joined(separator: "\n")
    }

    /// One line of shell that installs the right snippet for whichever shell is
    /// reading it, and nothing at all for a shell that is neither.
    ///
    /// Both payloads travel in the same line and the *shell* picks — rather
    /// than Portside detecting the shell first — because detection means a
    /// second ssh at connect time, racing the ControlMaster socket the
    /// interactive session is still bringing up. Letting the remote decide
    /// costs bytes instead of a round trip, and bytes are the cheaper problem.
    ///
    /// **On size:** the line is 2346 bytes, which is long enough to be worth
    /// checking against the tty rather than assuming. Measured rather than
    /// taken from the POSIX `MAX_CANON` folklore — a real bash and a real zsh
    /// on a Darwin pty both accept the whole line and report correctly, so the
    /// 1024-byte figure that number suggests is not what the line discipline
    /// actually enforces here. Confirmed against **Linux** hosts too by
    /// `ShellIntegrationRemoteTests`, which is the line discipline that
    /// actually receives it in the field.
    ///
    /// What *does* bite at this length is the writer: a pty deadlocks if you
    /// push a long line in without draining the echo coming back, because the
    /// output buffer fills, the shell blocks writing its echo, and it therefore
    /// stops reading your input. Portside is never exposed to that — the bytes
    /// go to ssh's stdin, a pipe, and SwiftTerm drains the session's output
    /// continuously — but it is the reason a naive harness testing this appears
    /// to prove a size limit that isn't there. `fitsCanonicalBuffer` keeps a
    /// budget anyway, against a limit generous enough to be a real signal.
    ///
    /// `base64 -d` is GNU/busybox; `-D` is the BSD spelling. Older macOS wants
    /// the second, newer accepts either, so it tries both and stays quiet when
    /// the first fails. A host with no `base64` at all evaluates an empty
    /// string, which is a no-op — the same place we were before injecting.
    ///
    /// The leading space is a nod to `HISTCONTROL=ignorespace` /
    /// `setopt histignorespace`. Neither is on by default, so this keeps the
    /// line out of history on hosts configured for it and not on the rest.
    static var command: String {
        let bash = encoded(.bash)
        let zsh = encoded(.zsh)
        return " __p=''; "
            + "[ -n \"$BASH_VERSION\" ] && __p='\(bash)'; "
            + "[ -n \"$ZSH_VERSION\" ] && __p='\(zsh)'; "
            + "[ -n \"$__p\" ] && eval \"$(printf %s \"$__p\" | base64 -d 2>/dev/null "
            + "|| printf %s \"$__p\" | base64 -D 2>/dev/null)\"; "
            + "unset __p"
    }

    static func encoded(_ snippet: ShellIntegrationSnippet) -> String {
        Data(payload(for: snippet).utf8).base64EncodedString()
    }

    /// Linux's `N_TTY` canonical buffer, and the most restrictive figure with
    /// evidence behind it. Kept as the budget because it is comfortably above
    /// what we send and comfortably below where anything is known to break.
    static let canonicalBudget = 4096

    /// Whether the line clears a given tty line buffer. Exposed so a test can
    /// hold the line to a budget: the snippet is edited far more often than
    /// this file, and base64 turns every 3 bytes added there into 4 here, so
    /// the encoded form grows faster than the thing being edited.
    static func fitsCanonicalBuffer(_ limit: Int) -> Bool {
        command.utf8.count <= limit
    }

    static var commandByteCount: Int { command.utf8.count }
}
