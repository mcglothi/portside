import Foundation

/// The one place that says what `ssh` Portside runs for an entry.
///
/// Extracted from `SessionManager.makeSession` when "Explain This Connection"
/// arrived. The explanation runs `ssh -G` to ask ssh what a connection would
/// resolve to, and that answer is only true if it is asked with the *same*
/// arguments the real connection uses — the entry's identity file, port and
/// host-key policy are command-line options, and command-line options outrank
/// `~/.ssh/config`. Two copies of this list would drift, and the failure mode
/// is a panel that confidently describes a connection nobody makes.
enum SSHInvocation {
    static let executable = "/usr/bin/ssh"

    /// `autoAcceptNewHostKeys` trusts an unknown host's key on first connect
    /// without prompting. ssh still hard-fails when an *already known* host's
    /// key later changes — that is the actual protection against interception,
    /// and it stays intact.
    static func arguments(for entry: SessionEntry, autoAcceptNewHostKeys: Bool) -> [String] {
        var hostKeyOptions: [String] = []
        if autoAcceptNewHostKeys {
            hostKeyOptions = ["-o", "StrictHostKeyChecking=accept-new"]
        }
        return SSHControl.options + hostKeyOptions + entry.sshArgs
    }

    /// The same invocation, asked to resolve and print rather than connect.
    ///
    /// `-G` makes ssh compute its effective configuration and exit without
    /// opening a connection, so this contacts nothing and cannot authenticate,
    /// prompt, or change a known-hosts file.
    static func explainArguments(
        for entry: SessionEntry, autoAcceptNewHostKeys: Bool
    ) -> [String] {
        ["-G"] + arguments(for: entry, autoAcceptNewHostKeys: autoAcceptNewHostKeys)
    }
}
