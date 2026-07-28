import Foundation

/// POSIX shell quoting for commands that must cross a shell.
///
/// Some commands genuinely have to be strings: `ssh host <command>` is
/// interpreted by the remote login shell no matter what we do locally, so an
/// argument array isn't available on that path. That makes correct quoting the
/// only defence, and it has to be applied at construction rather than trusted
/// to callers.
///
/// This matters because inventory metadata is *untrusted*: Portside imports
/// portable JSON libraries and MobaXterm sessions, so a Kubernetes namespace or
/// context can carry anything a crafted file wants it to.
enum ShellQuoting {

    /// Wraps a value so a POSIX shell reproduces it verbatim.
    ///
    /// Single quotes suppress every form of expansion — variables, command
    /// substitution, globbing, backslashes. The only character that can't
    /// appear inside them is a single quote itself, which is closed, escaped,
    /// and reopened: `it's` becomes `'it'\''s'`.
    static func quote(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        // Unreserved characters are safe bare, which keeps ordinary commands
        // readable in logs and error messages.
        let safe = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./:=@")
        if value.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Joins an argument array into a single shell-safe command string.
    static func command(_ parts: [String]) -> String {
        parts.map(quote).joined(separator: " ")
    }
}

extension String {
    /// Strips ASCII control characters (including escape) other than tab,
    /// so an imported field can't smuggle terminal escape sequences or
    /// otherwise-invisible bytes into a command that gets typed into a shell.
    var strippingControlCharacters: String {
        String(unicodeScalars.filter { scalar in
            scalar == "\t" || !(scalar.value < 0x20 || scalar.value == 0x7f)
        })
    }

    /// True when a value that will land in a positional argument slot could
    /// instead be parsed as a flag by the tool it's handed to — e.g. an
    /// imported container/pod name of `--privileged` or `-oProxyCommand=...`.
    var looksLikeShellOption: Bool {
        hasPrefix("-")
    }
}
