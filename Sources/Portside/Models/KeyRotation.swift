import Foundation

/// One rotation in progress: which hosts, which two keys, and what each host has
/// proved so far.
///
/// A model rather than view state, for the same reason `KeyDistributionPlan` is
/// one: the gating *is* the feature, and it should be provable without a window.
///
/// ## "Verified in this session" is enforced by this type existing
///
/// The rule from `road-to-1.0.md` is that retirement is offered only for hosts
/// that passed verify **in this session** — not "have ever passed", because a
/// verification from last week says nothing about a host someone has since
/// rebuilt. That is enforced structurally rather than by a timestamp: the two
/// keys are `let`, results live only in this instance, and nothing persists. A
/// rotation aimed at a different key is necessarily a different `KeyRotation`,
/// so its verifications cannot be inherited.
struct KeyRotation: Equatable {

    /// The three phases, in the order the user drives them. Never one button —
    /// each is a separate deliberate act, and only the third is destructive.
    enum Phase: Int, CaseIterable, Identifiable {
        case add, verify, retire
        var id: Int { rawValue }

        var title: String {
            switch self {
            case .add: return "Add the new key"
            case .verify: return "Verify it works"
            case .retire: return "Retire the old key"
            }
        }

        /// What this phase does to a host, in one line, for the UI.
        var explanation: String {
            switch self {
            case .add:
                return "Adds the new key to each host, leaving the old one in place. "
                     + "Repeatable and non-destructive."
            case .verify:
                return "Logs in with the new key alone and confirms the host accepted it. "
                     + "Changes nothing."
            case .retire:
                return "Removes the old key — only from hosts that just proved the new one works."
            }
        }
    }

    let hosts: [SessionEntry]
    /// The key being retired. Optional because add and verify are useful on
    /// their own, and a rotation can be started before deciding what to drop.
    let oldKey: PublicKey?
    let newKey: PublicKey
    /// Install into this account rather than each host's login user; `sudo` on
    /// the host, as in a key push.
    let account: String

    private(set) var added: [UUID: KeyPushOutcome] = [:]
    private(set) var verified: [UUID: KeyVerifyOutcome] = [:]
    private(set) var retired: [UUID: KeyRetireOutcome] = [:]

    init(hosts: [SessionEntry], newKey: PublicKey, oldKey: PublicKey? = nil, account: String = "") {
        self.hosts = hosts
        self.newKey = newKey
        self.oldKey = oldKey
        self.account = account
    }

    /// The same rotation aimed at a different set of hosts, keeping what each
    /// surviving host has already proved.
    ///
    /// Ticking another host does not invalidate what a *different* host proved
    /// about the key, so those results are carried over. Changing either **key**
    /// invalidates everything — which is why that is not expressible here at
    /// all: the keys are `let`, so a different key is necessarily a different
    /// `KeyRotation` with no history.
    func retargeted(to hosts: [SessionEntry]) -> KeyRotation {
        var moved = KeyRotation(hosts: hosts, newKey: newKey, oldKey: oldKey, account: account)
        let surviving = Set(hosts.map(\.id))
        moved.added = added.filter { surviving.contains($0.key) }
        moved.verified = verified.filter { surviving.contains($0.key) }
        moved.retired = retired.filter { surviving.contains($0.key) }
        return moved
    }

    // MARK: - Recording

    mutating func record(_ outcome: KeyPushOutcome, forHost id: UUID) {
        added[id] = outcome
    }

    /// Records a verification.
    ///
    /// A *failed* verify clears any earlier pass for that host rather than
    /// leaving the old one standing. Re-verifying is how someone checks a host
    /// they have just changed, and "it worked the first time I asked" is not a
    /// reason to keep permission to delete its old key.
    mutating func record(_ outcome: KeyVerifyOutcome, forHost id: UUID) {
        verified[id] = outcome
    }

    mutating func record(_ outcome: KeyRetireOutcome, forHost id: UUID) {
        retired[id] = outcome
    }

    // MARK: - The gate

    /// Whether this host may have its old key removed.
    ///
    /// The only route to true is a `.verified` recorded on this instance. Note
    /// what is deliberately *not* consulted: whether the push succeeded. A push
    /// reports that a line was appended, which is not evidence that sshd will
    /// authenticate with it — `StrictModes`, an `AuthorizedKeysFile` pointing
    /// elsewhere, or a restrictive `Match` block all leave a correct-looking
    /// file that authenticates nothing.
    func canRetire(hostID id: UUID) -> Bool {
        guard canRetireAnything else { return false }
        return verified[id]?.provesKeyWorks == true
    }

    /// Hosts that have proved the new key works and can therefore lose the old
    /// one, in display order.
    var retirable: [SessionEntry] {
        hosts.filter { canRetire(hostID: $0.id) }
    }

    /// Hosts that verified but whose old key is still in place — what the retire
    /// button acts on.
    var awaitingRetirement: [SessionEntry] {
        retirable.filter { retired[$0.id] == nil }
    }

    /// Why retirement is unavailable at all, if it is. Separate from the
    /// per-host gate so the UI can explain the situation once instead of
    /// showing every row as blocked for a reason that isn't about the row.
    var retirementBlocker: String? {
        guard let oldKey else { return "Choose the key you want to retire." }
        if oldKey.identityFields == newKey.identityFields {
            return "The old and new keys are the same key — there is nothing to rotate."
        }
        if retirable.isEmpty {
            return "No host has proved the new key works yet. Verify first."
        }
        return nil
    }

    private var canRetireAnything: Bool {
        guard let oldKey else { return false }
        // Retiring a key that *is* the new key would remove what was just
        // installed. The remote script refuses this too, and restores from its
        // backup if a rewrite ever loses the new key — but a mistake this
        // consequential should not need the host to catch it.
        return oldKey.identityFields != newKey.identityFields
    }

    // MARK: - Counts, for the UI and the confirmation

    var verifiedCount: Int { hosts.filter { verified[$0.id]?.provesKeyWorks == true }.count }
    var addedCount: Int { hosts.filter { added[$0.id]?.hostTrustsKey == true }.count }
    var retiredCount: Int { hosts.filter { retired[$0.id]?.isSuccess == true }.count }

    /// Hosts that verified but where the push had *not* reported the key as
    /// installed — worth surfacing rather than hiding, because it usually means
    /// the key was already there by another route, and occasionally that the
    /// verification is riding on something other than what was pushed.
    var verifiedWithoutSuccessfulPush: [SessionEntry] {
        hosts.filter {
            verified[$0.id]?.provesKeyWorks == true && added[$0.id]?.hostTrustsKey != true
        }
    }

    /// The sentence the retire confirmation leads with. Names the count and the
    /// key; the confirmation itself lists every host, as a push does.
    func retirementSummary() -> String {
        let hosts = awaitingRetirement.count
        let noun = hosts == 1 ? "1 host" : "\(hosts) hosts"
        let name = oldKey?.filename ?? "the old key"
        return "Remove \(name) from \(noun)"
    }
}
