import Foundation

/// What this connection would actually do, before it does it.
///
/// "Where does this session actually go, as which user, through what, with
/// which key?" was only answerable by reading the entry, then `~/.ssh/config`,
/// then working out which `Host` block won. ssh already computes that answer —
/// `ssh -G` prints the effective configuration and connects to nothing — so
/// this asks ssh rather than reimplementing its precedence rules.
///
/// **It is asked using the same arguments Portside would connect with.**
/// Running `ssh -G <host>` alone would describe a *different* connection than
/// the one Portside makes, because the entry's own identity file, port and
/// ControlMaster options are passed on the command line and outrank the config
/// file. A panel that explained the wrong connection would be worse than none.
///
/// **No secrets.** `ssh -G` prints paths and policies, never key material or
/// passwords. The credential line names the *source* that would be used —
/// `CredentialResolver.Source` — and never reads the Keychain to do it.
struct ConnectionExplanation: Equatable {

    /// A field of the effective configuration, ready to display.
    struct Item: Equatable, Identifiable {
        var label: String
        var value: String
        /// Why this line matters, when it isn't obvious.
        var note: String?
        var id: String { label }
    }

    /// The destination as ssh resolved it, e.g. "tim@10.0.0.4:22".
    var destination: String
    var items: [Item]
    /// Set when `ssh -G` itself failed — a malformed config, or a host that
    /// cannot be parsed. The panel shows this instead of a half-built answer.
    var failure: String?

    // MARK: - Parsing

    /// Builds an explanation from `ssh -G` output.
    ///
    /// The format is one `keyword value` per line, lowercased keywords, with
    /// repeats for multi-valued keys (`identityfile` in particular). Unknown
    /// keywords are ignored rather than shown: the raw output runs to ~80
    /// lines of defaults nobody asked about.
    static func parse(
        sshDashG output: String, credentialSource: CredentialResolver.Source
    ) -> ConnectionExplanation {
        var values: [String: [String]] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            values[parts[0].lowercased(), default: []].append(
                parts[1].trimmingCharacters(in: .whitespaces)
            )
        }

        let host = values["hostname"]?.first ?? ""
        let user = values["user"]?.first ?? ""
        let port = values["port"]?.first ?? "22"
        var items: [Item] = []

        if !host.isEmpty {
            items.append(Item(
                label: "Resolves to", value: host,
                note: "The address ssh will actually dial. A Host alias in "
                    + "~/.ssh/config can point somewhere other than its own name."
            ))
        }
        if !user.isEmpty { items.append(Item(label: "Logs in as", value: user, note: nil)) }
        items.append(Item(label: "Port", value: port, note: nil))

        if let jump = values["proxyjump"]?.first, jump.lowercased() != "none" {
            items.append(Item(
                label: "Jumps through", value: jump,
                note: "Traffic reaches the host via this intermediary, which "
                    + "must itself be reachable and authenticate first."
            ))
        }
        if let command = values["proxycommand"]?.first, !command.isEmpty {
            items.append(Item(
                label: "Proxy command", value: command,
                note: "An external program carries the connection."
            ))
        }

        // ssh offers identity files in order and stops at the first the host
        // accepts, so the list — and its order — is the answer to "which key
        // did it use?". Nonexistent paths are listed by ssh regardless of
        // whether the file is there; that is ssh's own output, not a claim
        // that the key exists.
        if let identities = values["identityfile"], !identities.isEmpty {
            let onlyThese = values["identitiesonly"]?.first?.lowercased() == "yes"
            items.append(Item(
                label: identities.count == 1 ? "Identity file" : "Identity files",
                value: identities.map(abbreviatingHome).joined(separator: "\n"),
                note: onlyThese
                    ? "IdentitiesOnly is set, so only these are offered."
                    : "Offered in this order until one is accepted. These are the "
                        + "paths ssh would try — it does not check here whether they exist."
            ))
        }

        if let checking = values["stricthostkeychecking"]?.first {
            items.append(Item(
                label: "Host key policy", value: checking,
                note: hostKeyNote(for: checking)
            ))
        }
        if let known = values["userknownhostsfile"]?.first {
            // ssh returns this as several space-separated paths on one line
            // (known_hosts and known_hosts2 by default), so it has to be split
            // before abbreviating or only the first one reads as ~/.
            let paths = known.split(separator: " ").map { abbreviatingHome(String($0)) }
            items.append(Item(
                label: paths.count == 1 ? "Known hosts" : "Known hosts files",
                value: paths.joined(separator: "\n"), note: nil
            ))
        }

        items.append(Item(
            label: "Stored password",
            value: describe(credentialSource),
            note: credentialSource == .none
                ? "No saved password applies, so ssh will prompt in the terminal."
                : "Portside supplies this through an askpass helper; the value never "
                    + "appears in the command line or in a log."
        ))

        let destination = [user.isEmpty ? nil : "\(user)@", host.isEmpty ? nil : host,
                           port == "22" ? nil : ":\(port)"]
            .compactMap { $0 }.joined()

        return ConnectionExplanation(
            destination: destination.isEmpty ? "(unresolved)" : destination,
            items: items,
            failure: nil
        )
    }

    private static func hostKeyNote(for policy: String) -> String? {
        switch policy.lowercased() {
        case "accept-new":
            return "An unknown host is trusted on first connect without asking. A "
                + "change to an already-known key still fails, which is the part "
                + "that protects against interception."
        case "no", "off":
            return "Host keys are not verified. This accepts an interception silently."
        case "yes":
            return "Only hosts already in the known-hosts file are accepted."
        default:
            return nil
        }
    }

    private static func describe(_ source: CredentialResolver.Source) -> String {
        switch source {
        case .none: return "None"
        case .assignedProfile: return "From the credential profile assigned to this host"
        case .hostSpecific: return "Saved against this host"
        case .defaultProfile: return "From the default credential profile"
        case .legacyDefault: return "From the app-wide default password"
        }
    }

    /// `/Users/tim/.ssh/id_ed25519` reads as `~/.ssh/id_ed25519`, which is how
    /// the user wrote it and how it appears in their config.
    ///
    /// ssh is inconsistent about this in its own output — `identityfile` comes
    /// back already tilde-form, `userknownhostsfile` absolute — so this runs
    /// over both and is a no-op on the ones ssh already shortened.
    private static func abbreviatingHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
