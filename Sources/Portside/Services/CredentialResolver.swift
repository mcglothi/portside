import Foundation

/// The single answer to "which password does this host use?".
///
/// The precedence rule existed in `SessionManager` only, and `TunnelManager`
/// reimplemented a fragment of it — checking the host's own Keychain entry and
/// nothing else. Standalone and auto-start tunnels therefore failed for any
/// host that relies on an assigned or default credential profile, which is the
/// arrangement profiles exist to support in the first place.
///
/// Anything that needs to authenticate as a host resolves through here.
enum CredentialResolver {

    /// Password for `entry`, honouring profile assignment and defaults.
    ///
    /// Order: the host's assigned profile, then a password stored against the
    /// host itself, then the default profile, then the legacy default. A host
    /// that hasn't opted into saved passwords resolves to nil regardless of
    /// what's stored — the toggle is the user's consent, not a hint.
    static func password(for entry: SessionEntry, defaultProfileID: UUID?) -> String? {
        guard entry.savePassword else { return nil }
        return entry.credentialProfileID.flatMap(CredentialStore.profilePassword)
            ?? CredentialStore.password(for: entry.id)
            ?? defaultProfileID.flatMap(CredentialStore.profilePassword)
            ?? CredentialStore.defaultPassword()
    }

    /// Describes the precedence without reading the Keychain, so the order can
    /// be tested without touching real credentials. `CredentialStore` wraps the
    /// system Keychain with no test seam, and exercising it from tests has
    /// destroyed a real entry before now.
    enum Source: Equatable {
        case none
        case assignedProfile
        case hostSpecific
        case defaultProfile
        case legacyDefault
    }

    static func source(
        savePassword: Bool,
        hasAssignedProfilePassword: Bool,
        hasHostPassword: Bool,
        hasDefaultProfilePassword: Bool,
        hasLegacyDefault: Bool
    ) -> Source {
        guard savePassword else { return .none }
        if hasAssignedProfilePassword { return .assignedProfile }
        if hasHostPassword { return .hostSpecific }
        if hasDefaultProfilePassword { return .defaultProfile }
        if hasLegacyDefault { return .legacyDefault }
        return .none
    }
}
