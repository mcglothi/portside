import Foundation

/// Runs `ssh -G` and turns its answer into something readable.
///
/// Separate from `ConnectionExplanation` so the parsing — the part with the
/// judgement in it — is testable without running a process.
enum ConnectionExplainer {

    /// Asks ssh what this entry's connection resolves to.
    ///
    /// Contacts no host: `-G` computes the configuration and exits. Reads no
    /// Keychain either — `credentialSource` is decided from flags the caller
    /// already holds, so no password is fetched to describe one.
    static func explain(
        entry: SessionEntry,
        autoAcceptNewHostKeys: Bool,
        credentialSource: CredentialResolver.Source
    ) async -> ConnectionExplanation {
        guard entry.kind == .host else {
            return ConnectionExplanation(
                destination: entry.subtitle, items: [],
                failure: "Only SSH sessions have an ssh configuration to explain. "
                    + "This is a \(entry.kind.label.lowercased()) session."
            )
        }

        let arguments = SSHInvocation.explainArguments(
            for: entry, autoAcceptNewHostKeys: autoAcceptNewHostKeys
        )
        do {
            let result = try await SFTPClient.runProcess(
                SSHInvocation.executable, arguments, stdin: ""
            )
            guard result.status == 0 else {
                // A malformed ~/.ssh/config, or an unparseable host. ssh's own
                // complaint is more useful than anything we would write.
                return ConnectionExplanation(
                    destination: entry.subtitle, items: [],
                    failure: result.err.trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
                        ? "ssh -G exited with status \(result.status)."
                        : result.err.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            var explanation = ConnectionExplanation.parse(
                sshDashG: result.out, credentialSource: credentialSource
            )
            if entry.preferMosh {
                explanation.items.append(ConnectionExplanation.Item(
                    label: "Transport",
                    value: MoshLocator.find() == nil ? "ssh (mosh requested, not installed)" : "mosh",
                    note: MoshLocator.find() == nil
                        ? "mosh is set for this host but isn't installed, so ssh is used."
                        : "mosh bootstraps over ssh, so the settings above still apply to "
                            + "that first connection. ControlMaster does not, which is why "
                            + "the file browser is unavailable for mosh sessions."
                ))
            }
            return explanation
        } catch {
            return ConnectionExplanation(
                destination: entry.subtitle, items: [],
                failure: error.localizedDescription
            )
        }
    }
}
