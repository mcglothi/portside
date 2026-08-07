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
