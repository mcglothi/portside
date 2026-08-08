import Foundation

/// Which hosts a key push is aimed at, and the rules about how that set may be
/// built.
///
/// A model rather than view state because these rules are the safety story, and
/// the safety story should be testable without a window. The one that matters:
/// **a bulk action never sweeps in a protected host.** That mirrors MultiExec,
/// where the same rule exists because "select all" is how someone ends up
/// running something on the production box they had deliberately fenced off.
struct KeyDistributionPlan: Equatable {
    /// Every host the key *could* go to, in display order.
    let candidates: [SessionEntry]
    /// Ticked hosts.
    private(set) var selected: Set<UUID> = []

    init(candidates: [SessionEntry], selected: Set<UUID> = []) {
        self.candidates = candidates
        self.selected = selected.filter { id in candidates.contains { $0.id == id } }
    }

    /// Only hosts. Serial, telnet and local container sessions have no
    /// `authorized_keys` to write to, so they are never candidates.
    static func candidates(from entries: [SessionEntry]) -> [SessionEntry] {
        entries.filter { $0.kind == .host && !$0.usesLocalTransport }
    }

    var selectedEntries: [SessionEntry] {
        candidates.filter { selected.contains($0.id) }
    }

    var protectedSelected: [SessionEntry] {
        selectedEntries.filter(\.isProtected)
    }

    var isEmpty: Bool { selected.isEmpty }
    var count: Int { selected.count }

    func isSelected(_ entry: SessionEntry) -> Bool { selected.contains(entry.id) }

    /// Ticking one host by hand is always allowed, protected or not — the point
    /// of `isProtected` is that including it has to be a decision, not that it
    /// is impossible.
    mutating func toggle(_ entry: SessionEntry) {
        if selected.contains(entry.id) {
            selected.remove(entry.id)
        } else {
            selected.insert(entry.id)
        }
    }

    mutating func set(_ entry: SessionEntry, selected isOn: Bool) {
        if isOn { selected.insert(entry.id) } else { selected.remove(entry.id) }
    }

    /// **Never selects a protected host.** A protected host already ticked by
    /// hand stays ticked — this adds, it does not reset.
    mutating func selectAll() {
        for entry in candidates where !entry.isProtected {
            selected.insert(entry.id)
        }
    }

    mutating func selectNone() {
        selected.removeAll()
    }

    /// Whether "Select All" would still leave something unticked, so the button
    /// can say so rather than looking broken when protected hosts are present.
    var protectedCandidates: [SessionEntry] {
        candidates.filter(\.isProtected)
    }

    /// A one-line description of what is about to happen, for the confirmation.
    /// Deliberately counts rather than summarising: the confirmation itself
    /// names every host.
    func summary(keyName: String) -> String {
        let hosts = count == 1 ? "1 host" : "\(count) hosts"
        return "Add \(keyName) to \(hosts)"
    }
}

// MARK: - Which account the key actually lands in

extension KeyDistributionPlan {

    /// One account the current selection would install the key for.
    struct AccountTarget: Equatable, Identifiable {
        /// nil when the account comes from `~/.ssh/config` and Portside can't
        /// know it — an aliased host whose `User` lives in the config file.
        let account: String?
        let hostCount: Int
        var id: String { account ?? "\u{0000}config" }
        var label: String { account ?? "from ~/.ssh/config" }
    }

    /// The accounts the selected hosts resolve to, commonest first.
    ///
    /// Built from `candidates`, which are already `SessionStore.resolved`
    /// entries — so this is the account ssh will actually log in as, not the
    /// one typed on the host.
    var targetAccounts: [AccountTarget] {
        var counts: [String?: Int] = [:]
        for entry in selectedEntries {
            counts[resolvedAccount(of: entry), default: 0] += 1
        }
        return counts
            .map { AccountTarget(account: $0.key, hostCount: $0.value) }
            .sorted {
                $0.hostCount == $1.hostCount
                    ? ($0.account ?? "") < ($1.account ?? "")
                    : $0.hostCount > $1.hostCount
            }
    }

    /// An aliased host's `User` is `~/.ssh/config`'s to decide; `resolved`
    /// deliberately leaves it unset rather than guessing.
    private func resolvedAccount(of entry: SessionEntry) -> String? {
        guard entry.sshAlias?.isEmpty ?? true else { return nil }
        let user = (entry.user ?? "").trimmingCharacters(in: .whitespaces)
        return user.isEmpty ? nil : user
    }

    /// The account to prefill the override field with — **only** when doing so
    /// is provably a no-op.
    ///
    /// That means every selected host already resolves to this exact account.
    /// Prefill anything else and an untouched field silently becomes a real
    /// override: hosts that resolved to something else get retargeted, and an
    /// aliased host gets a `-l` that overrides its `~/.ssh/config` entry. The
    /// point of prefilling is to make the destination obvious and one word
    /// away from being changed, not to quietly change it.
    var prefillAccount: String? {
        let targets = targetAccounts
        guard targets.count == 1, let account = targets[0].account else { return nil }
        return account
    }

    /// A plain sentence naming where the key lands, for the line under the key.
    func accountSummary(override: String) -> String {
        let override = override.trimmingCharacters(in: .whitespaces)
        let hosts = count == 1 ? "host" : "all \(count) hosts"
        if !override.isEmpty {
            return "Lands in \(override)’s home on \(hosts)."
        }
        let targets = targetAccounts
        switch targets.count {
        case 0:
            return "No hosts selected yet."
        case 1:
            guard let account = targets[0].account else {
                return "Lands in whichever account ~/.ssh/config logs in as."
            }
            return "Lands in \(account)’s home on \(hosts)."
        default:
            let parts = targets.map { "\($0.label) (\($0.hostCount))" }.joined(separator: ", ")
            return "Lands in each host’s own account — \(parts)."
        }
    }
}
