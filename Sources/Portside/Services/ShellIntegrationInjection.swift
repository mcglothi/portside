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

    /// Lines of shell that install the right snippet for whichever shell is
    /// reading them, and nothing at all for a shell that is neither — joined
    /// with Returns, ready to type.
    ///
    /// Both payloads travel and the *shell* picks — rather than Portside
    /// detecting the shell first — because detection means a second ssh at
    /// connect time, racing the ControlMaster socket the interactive session
    /// is still bringing up. Letting the remote decide costs bytes instead of
    /// a round trip.
    ///
    /// **On size: every line stays under `maxLineBytes`.** The text is often
    /// typed before ssh has put the *local* pty into raw mode — with key auth
    /// the session can be ready for it before ssh has switched — and until
    /// then the pty is in canonical mode, where Darwin keeps at most 1024
    /// bytes of a line (`MAX_CANON`). It was once one 2346-byte line: the
    /// tty cut it off, its Return was lost, and when ssh went raw the part
    /// that fit reached the remote prompt as base64 junk (seen on real hosts
    /// on 2026-10-08). An earlier measurement here missed it because it typed
    /// into bash and zsh directly, and their line editors read in raw mode.
    /// So the payloads go as short assignments, `__p_b0='…'`, `__p_b1='…'`,
    /// and a last line assembles the right one and evals it. Short lines also
    /// clear a remote host's own canonical buffer, a macOS host's included.
    ///
    /// `base64 -d` is GNU/busybox; `-D` is the BSD spelling. Older macOS wants
    /// the second, newer accepts either, so it tries both and stays quiet when
    /// the first fails. A host with no `base64` at all evaluates an empty
    /// string, which is a no-op — the same place we were before injecting.
    ///
    /// The leading space on each line is a nod to `HISTCONTROL=ignorespace` /
    /// `setopt histignorespace`. Neither is on by default, so this keeps the
    /// lines out of history on hosts configured for it and not on the rest.
    static var command: String { lines.joined(separator: "\r") }

    static var lines: [String] {
        let bash = chunks(encoded(.bash)), zsh = chunks(encoded(.zsh))
        var out: [String] = []
        var names: [String] = []
        func assign(_ prefix: String, _ parts: [String]) -> String {
            parts.indices.map { i -> String in
                let name = "__p_\(prefix)\(i)"
                names.append(name)
                out.append(" \(name)='\(parts[i])'")
                return "$\(name)"
            }.joined()
        }
        let bashValue = assign("b", bash), zshValue = assign("z", zsh)
        out.append(" __p=''; "
            + "[ -n \"$BASH_VERSION\" ] && __p=\"\(bashValue)\"; "
            + "[ -n \"$ZSH_VERSION\" ] && __p=\"\(zshValue)\"; "
            + "[ -n \"$__p\" ] && eval \"$(printf %s \"$__p\" | base64 -d 2>/dev/null "
            + "|| printf %s \"$__p\" | base64 -D 2>/dev/null)\"; "
            + "unset __p \(names.joined(separator: " "))")
        out.append(promptOnlyLine)
        return out
    }

    /// For a sh-family shell that is neither bash nor zsh — `ash`, `dash`,
    /// BusyBox `sh`, `ksh` — which has no hook to run before a command: the
    /// prompt itself reports the previous command's exit status (`133;D;$?`)
    /// and the directory (OSC 7), marks its start (`A`) and its end (`B`).
    /// `CommandOutputCapture` reads the line typed after `B` as the command.
    /// Those shells expand `$?` and `$PWD` in `PS1` at every prompt (checked
    /// on Alpine, BusyBox and Debian's dash); nothing else here needs more
    /// than POSIX.
    ///
    /// The escape bytes come from `printf` at assignment time, so nothing in
    /// `PS1` relies on a shell interpreting backslashes there. The trailing
    /// `B` closes the line that installed it, so the first new prompt's `D`
    /// finds nothing typed and records nothing. A `PS1` that already carries
    /// the markers is left alone.
    static let promptOnlyLine = #" [ -z "$BASH_VERSION$ZSH_VERSION" ] && case "$PS1" in *'133;B'*) ;; *) "#
        + #"__e=$(printf '\033'); __a=$(printf '\007'); "#
        + #"PS1="$__e]133;D;\$?$__a$__e]7;file://${HOSTNAME:-$(hostname 2>/dev/null)}\$PWD$__a$__e]133;A$__a$PS1$__e]133;B$__a"; "#
        + #"printf '\033]133;B\007'; unset __e __a;; esac"#

    /// Base64 in pieces short enough that an assignment line holding one
    /// stays well under `maxLineBytes`.
    private static func chunks(_ text: String) -> [String] {
        let size = maxLineBytes - 40
        var out: [String] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            out.append(String(rest.prefix(size)))
            rest = rest.dropFirst(size)
        }
        return out
    }

    /// Whether the injection may be typed into `shell` — a container's or
    /// pod's configured shell. The lines are POSIX: bash and zsh get the full
    /// integration, other sh-family shells the prompt-only one, and fish, csh
    /// or nu would only print errors.
    static func acceptsInjection(shell: String) -> Bool {
        let name = (shell.trimmingCharacters(in: .whitespaces) as NSString).lastPathComponent
        return ["sh", "bash", "ash", "dash", "zsh", "ksh", "mksh"].contains(name)
    }

    static func encoded(_ snippet: ShellIntegrationSnippet) -> String {
        Data(payload(for: snippet).utf8).base64EncodedString()
    }

    /// The longest line typed. Darwin's canonical line buffer is 1024 bytes
    /// including the newline (`MAX_CANON`), the tightest of the systems this
    /// meets; this leaves margin under it.
    static let maxLineBytes = 900

    /// Whether every line clears a given tty line buffer. Exposed so a test can
    /// hold the lines to a budget: the snippet is edited far more often than
    /// this file, and base64 turns every 3 bytes added there into 4 here.
    static func fitsCanonicalBuffer(_ limit: Int) -> Bool {
        lines.allSatisfy { $0.utf8.count < limit }
    }

    static var commandByteCount: Int { command.utf8.count }
}
