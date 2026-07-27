import Foundation

/// What's unclassified or unconfigured across the host library.
///
/// The point is to make a bulk pass over a large inventory *verifiable* rather
/// than guessed at: after tagging 700 hosts, you want to see the remaining 200,
/// not hope you got them all.
///
/// Deliberately framed as **coverage, not errors**. A host with no saved
/// password and no key is perfectly healthy if it authenticates through
/// ssh-agent or a `~/.ssh/config` rule — Portside can't know, and shouldn't
/// imply otherwise. These are gaps in what *Portside* knows about the fleet,
/// which is a different question from whether the fleet works.
///
/// Pure so it tests without a store or a GUI.
enum InventoryCoverage {

    enum Gap: String, CaseIterable, Identifiable {
        case noEnvironment
        case noCredentialProfile
        case noStoredCredentials
        case stale

        var id: String { rawValue }

        var title: String {
            switch self {
            case .noEnvironment: return "No environment tag"
            case .noCredentialProfile: return "No credential profile"
            case .noStoredCredentials: return "No stored credentials"
            case .stale: return "Not connected recently"
            }
        }

        var icon: String {
            switch self {
            case .noEnvironment: return "tag"
            case .noCredentialProfile: return "person.badge.key"
            case .noStoredCredentials: return "key"
            case .stale: return "clock.arrow.circlepath"
            }
        }

        /// Says what the gap means *and* when it's fine, so the view doesn't
        /// read as a list of faults.
        var detail: String {
            switch self {
            case .noEnvironment:
                return "Not tagged prod/staging/dev/personal, so these are missing the badge and any protection that depends on knowing what they are."
            case .noCredentialProfile:
                return "Not using a shared profile, so a password or key rotation won't reach these hosts automatically — they'd each need editing."
            case .noStoredCredentials:
                return "No key, saved password, or profile is configured. Perfectly normal if these authenticate through ssh-agent or a ~/.ssh/config rule."
            case .stale:
                return "Connected to a long time ago. Often just infrastructure you don't touch often — worth a look when pruning a big imported library."
            }
        }
    }

    struct Finding: Identifiable {
        var id: String { gap.rawValue }
        let gap: Gap
        let entries: [SessionEntry]
    }

    /// Hosts matching each gap, in the fixed `Gap` order, skipping gaps with no
    /// hosts. Only real SSH-ish hosts are considered — a serial console or a
    /// local shell has no credentials to speak of, so counting them as gaps
    /// would be noise that never goes away.
    static func findings(
        entries: [SessionEntry],
        defaults: ConnectionDefaults,
        profiles: [CredentialProfile],
        staleIDs: Set<UUID> = []
    ) -> [Finding] {
        let candidates = entries.filter { $0.kind == .host }
        return Gap.allCases.compactMap { gap in
            let matched = candidates
                .filter { matches(gap, entry: $0, defaults: defaults, profiles: profiles, staleIDs: staleIDs) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return matched.isEmpty ? nil : Finding(gap: gap, entries: matched)
        }
    }

    static func matches(
        _ gap: Gap,
        entry: SessionEntry,
        defaults: ConnectionDefaults,
        profiles: [CredentialProfile],
        staleIDs: Set<UUID> = []
    ) -> Bool {
        switch gap {
        case .stale:
            return staleIDs.contains(entry.id)
        case .noEnvironment:
            return entry.environment == .none

        case .noCredentialProfile:
            // A dangling reference to a deleted profile is a gap too — the host
            // looks configured but resolves to nothing.
            guard let id = entry.credentialProfileID else { return true }
            return !profiles.contains { $0.id == id }

        case .noStoredCredentials:
            let profile = entry.credentialProfileID.flatMap { id in profiles.first { $0.id == id } }
            let hasProfileKey = !(profile?.identityFile?.isEmpty ?? true)
            let hasOwnKey = !(entry.identityFile?.isEmpty ?? true)
            let hasDefaultKey = !(defaults.identityFile?.isEmpty ?? true)
            // A profile is treated as carrying credentials even without a key
            // path: its password lives in the Keychain, which isn't readable
            // from here (and mustn't be touched just to draw a list).
            let hasProfile = profile != nil
            return !(hasProfileKey || hasOwnKey || hasDefaultKey || hasProfile || entry.savePassword)
        }
    }

    /// Share of hosts with no gaps at all, for an at-a-glance summary.
    /// Returns nil when there are no hosts to report on.
    /// Counts only the gaps a user can actually close for every host.
    ///
    /// Staleness is a usage fact, not a gap in what the library describes. And
    /// not using a *shared* profile is a legitimate choice — a host with its own
    /// key is fully configured — so counting it made 100% unreachable for
    /// perfectly good setups, which turns the number into noise. Both are still
    /// listed as findings; they just don't drag the score down.
    static func coveredFraction(
        entries: [SessionEntry],
        defaults: ConnectionDefaults,
        profiles: [CredentialProfile]
    ) -> Double? {
        let candidates = entries.filter { $0.kind == .host }
        guard !candidates.isEmpty else { return nil }
        let describedGaps: [Gap] = [.noEnvironment, .noStoredCredentials]
        let clean = candidates.filter { entry in
            !describedGaps.contains { matches($0, entry: entry, defaults: defaults, profiles: profiles) }
        }
        return Double(clean.count) / Double(candidates.count)
    }
}
