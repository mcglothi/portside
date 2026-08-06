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
    /// host itself, then the default profile, then the legacy default.
    ///
    /// `savePassword` gates only the two credentials belonging to the host —
    /// its own Keychain entry and the legacy app-wide default. A *profile*
    /// carries its own consent: assigning one to a host, or nominating one as
    /// the default in Settings ▸ Profiles, is the user saying "authenticate
    /// with this". Gating profiles behind the per-host toggle as well meant a
    /// correctly configured default profile was inert against every host that
    /// had never been individually ticked — which is the state a freshly
    /// imported library is in, so the feature appeared not to work at all.
    static func password(for entry: SessionEntry, defaultProfileID: UUID?) -> String? {
        if let assigned = entry.credentialProfileID.flatMap(CredentialStore.profilePassword) {
            return assigned
        }
        if entry.savePassword, let own = CredentialStore.password(for: entry.id) {
            return own
        }
        if let fallback = defaultProfileID.flatMap(CredentialStore.profilePassword) {
            return fallback
        }
        return entry.savePassword ? CredentialStore.defaultPassword() : nil
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
        if hasAssignedProfilePassword { return .assignedProfile }
        if savePassword, hasHostPassword { return .hostSpecific }
        if hasDefaultProfilePassword { return .defaultProfile }
        if savePassword, hasLegacyDefault { return .legacyDefault }
        return .none
    }
}
