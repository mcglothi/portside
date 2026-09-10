import Foundation

/// Why a session ended, inferred from the transport's own last words.
///
/// The bar under a dead pane said "Session ended" for every ending: a clean
/// `exit`, a DNS name that does not resolve, a changed host key, a refused
/// password. Those need different next actions, and the information to tell
/// them apart was already on screen — ssh writes its diagnostics to the pty,
/// so they are in the terminal — but the user had to know what they were
/// reading.
///
/// This is a **heuristic over OpenSSH's English messages**, not a parse of a
/// structured status. It is right for the endings people actually hit, and it
/// is deliberately built so that being wrong is cheap: every diagnosis carries
/// the verbatim line it matched on, so the user sees the evidence and not just
/// our conclusion. An unrecognised ending says so rather than guessing.
struct ConnectionDiagnosis: Equatable {

    /// The endings worth telling apart. Anything else is `.unknown`, which
    /// reports the exit status and shows the output instead of inventing a
    /// cause for it.
    enum Cause: Equatable {
        case exitedNormally
        case hostNotFound
        case timedOut
        case connectionRefused
        case networkUnreachable
        case hostKeyChanged
        case hostKeyUnverified
        case authenticationFailed
        case tooManyAuthFailures
        case remoteCommandFailed(Int32)
        case unknown(Int32?)
    }

    var cause: Cause
    /// What to say in place of "Session ended".
    var headline: String
    /// The one thing worth doing next, or nil when there isn't a general one.
    var nextStep: String?
    /// The transport's own words, verbatim, so the reading can be checked.
    var evidence: String?

    /// Whether this ending is worth drawing attention to. A clean exit is not.
    var isFailure: Bool {
        if case .exitedNormally = cause { return false }
        return true
    }

    // MARK: - Classification

    /// OpenSSH reports its *own* failures as 255 and otherwise passes the
    /// remote command's status through, so 255 means "ssh could not do it"
    /// and anything else came from the far end.
    static let sshOwnFailure: Int32 = 255

    /// Reads `output` (the tail of what the session printed) and `exitCode`.
    ///
    /// Message text wins over exit status: ssh reports resolution failures,
    /// refused connections and host-key problems all as 255, so the status
    /// alone cannot separate them. `kind` keeps the reading honest for
    /// transports that are not ssh — a serial console's exit says nothing
    /// about DNS.
    static func diagnose(
        output: String, exitCode: Int32?, kind: SessionKind?
    ) -> ConnectionDiagnosis {
        let isSSH = (kind == .host || kind == nil)

        if isSSH, let match = sshSignature(in: output) {
            return match
        }

        switch exitCode {
        case 0?:
            return ConnectionDiagnosis(
                cause: .exitedNormally, headline: "Session ended", nextStep: nil, evidence: nil
            )
        case sshOwnFailure? where isSSH:
            return ConnectionDiagnosis(
                cause: .unknown(sshOwnFailure),
                headline: "ssh could not connect",
                nextStep: "ssh reported a failure of its own (status 255) without a message "
                    + "Portside recognises. The terminal above has its exact words.",
                evidence: lastNonEmptyLine(of: output)
            )
        case let code? where code != 0:
            return ConnectionDiagnosis(
                cause: .remoteCommandFailed(code),
                headline: "Session ended with status \(code)",
                nextStep: nil,
                evidence: lastNonEmptyLine(of: output)
            )
        default:
            return ConnectionDiagnosis(
                cause: .unknown(exitCode),
                headline: "Session ended",
                nextStep: nil,
                evidence: nil
            )
        }
    }

    /// Two passes, because two rules genuinely conflict.
    ///
    /// Most endings are best read from the *last* message: a session that
    /// retried can have an older, unrelated failure scrolled above the real
    /// one. But a changed host key prints its warning and then, several lines
    /// later, "Host key verification failed" — so recency alone files a
    /// possible interception under the mild "go accept the fingerprint"
    /// reading. The changed-key warning therefore wins wherever it appears,
    /// and everything else is decided by recency.
    /// Must stay in sync with the first entry of `signatures`, which is the
    /// one the override pass returns.
    private static let hostKeyChangedNeedle = "REMOTE HOST IDENTIFICATION HAS CHANGED"

    private static func sshSignature(in output: String) -> ConnectionDiagnosis? {
        let signatures: [(needles: [String], make: (String) -> ConnectionDiagnosis)] = [
            ([hostKeyChangedNeedle], { line in
                ConnectionDiagnosis(
                    cause: .hostKeyChanged,
                    headline: "The host's key changed since you last connected",
                    nextStep: "This is what a machine-in-the-middle would look like, and also "
                        + "what a rebuilt or re-imaged host looks like. Confirm the new "
                        + "fingerprint out of band before trusting it; if the host was "
                        + "genuinely rebuilt, remove the old entry with "
                        + "ssh-keygen -R <host>.",
                    evidence: line
                )
            }),
            (["Host key verification failed"], { line in
                ConnectionDiagnosis(
                    cause: .hostKeyUnverified,
                    headline: "The host's key was not accepted",
                    nextStep: "Portside did not have a trusted key for this host and could not "
                        + "verify the one offered. Connect once from a terminal to inspect "
                        + "and accept the fingerprint.",
                    evidence: line
                )
            }),
            (["Could not resolve hostname", "Name or service not known",
              "nodename nor servname provided"], { line in
                ConnectionDiagnosis(
                    cause: .hostNotFound,
                    headline: "That hostname didn't resolve",
                    nextStep: "DNS returned nothing for this name. Check the spelling, and "
                        + "whether this host needs a VPN or an internal resolver you are "
                        + "not currently using.",
                    evidence: line
                )
            }),
            (["Operation timed out", "Connection timed out", "Connection timeout"], { line in
                ConnectionDiagnosis(
                    cause: .timedOut,
                    headline: "The host never answered",
                    nextStep: "The name resolved but nothing replied before the timeout — "
                        + "usually a firewall dropping the packets, a host that is down, or "
                        + "the wrong port.",
                    evidence: line
                )
            }),
            (["Connection refused"], { line in
                ConnectionDiagnosis(
                    cause: .connectionRefused,
                    headline: "The host refused the connection",
                    nextStep: "Something answered and said no, so the host is up and reachable. "
                        + "Usually sshd is not running, or is listening on a different port.",
                    evidence: line
                )
            }),
            (["Network is unreachable", "No route to host"], { line in
                ConnectionDiagnosis(
                    cause: .networkUnreachable,
                    headline: "No route to that host",
                    nextStep: "The network itself has no path to this address — check the VPN "
                        + "or the interface you expect to reach it on.",
                    evidence: line
                )
            }),
            (["Too many authentication failures"], { line in
                ConnectionDiagnosis(
                    cause: .tooManyAuthFailures,
                    headline: "The host cut off authentication",
                    nextStep: "ssh offered more keys than the host would accept before it gave "
                        + "up. Naming the right identity for this host avoids offering the "
                        + "rest — and repeated attempts can lock an account out.",
                    evidence: line
                )
            }),
            (["Permission denied", "Authentication failed"], { line in
                ConnectionDiagnosis(
                    cause: .authenticationFailed,
                    headline: "The host rejected the credentials",
                    nextStep: "Reached the host, but it refused the key or password offered. "
                        + "Explain This Connection shows which identity and which stored "
                        + "credential this session would use.",
                    evidence: line
                )
            })
        ]

        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // Pass 1: the overriding reading, wherever it sits.
        if let warning = lines.first(where: { $0.contains(hostKeyChangedNeedle) }) {
            return signatures[0].make(warning)
        }

        // Pass 2: most recent message wins.
        for line in lines.reversed() {
            for signature in signatures.dropFirst()
            where signature.needles.contains(where: line.contains) {
                return signature.make(line)
            }
        }
        return nil
    }

    private static func lastNonEmptyLine(of output: String) -> String? {
        output.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { !$0.isEmpty }
    }
}
