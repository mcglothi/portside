import Foundation

/// Ties a credential profile's identity file to the hosts that authenticate
/// with it, so the key can actually be *installed* on them.
///
/// A profile says "these hosts log in with this key". Portside has never been
/// able to make that true — it configures `ssh -i` and hopes the host already
/// trusts the key. This closes that loop: the profile knows which hosts, and
/// key distribution knows how to install it.
enum CredentialProfileKey {

    /// The public key file beside a profile's identity file.
    ///
    /// A profile stores the *private* key path (`~/.ssh/id_ed25519`), which is
    /// what `ssh -i` wants and is emphatically not what gets pushed. The
    /// public half is the same path with `.pub`. Returns nil when the profile
    /// has no identity file, or when the `.pub` isn't there — a profile
    /// pointing at a key whose public half is missing is a real situation
    /// (agent-only setups, keys copied without their pair) and should offer
    /// nothing rather than guess.
    static func publicKeyPath(
        for profile: CredentialProfile,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String? {
        guard let identity = profile.identityFile?.trimmingCharacters(in: .whitespaces),
              !identity.isEmpty else { return nil }
        let expanded = (identity as NSString).expandingTildeInPath
        // Tolerate a profile that already points at the .pub — people do.
        let candidate = expanded.hasSuffix(".pub") ? expanded : expanded + ".pub"
        return fileExists(candidate) ? candidate : nil
    }

    /// The hosts that would authenticate with `profile`.
    ///
    /// Two populations, and the difference matters enough to be explicit:
    ///
    /// - Hosts **explicitly assigned** the profile.
    /// - If this is the *default* profile, also every host that has no profile
    ///   of its own, because those fall back to it. That can be most of the
    ///   library, which is exactly why the count goes in the button's title and
    ///   the sheet still names every host before anything is contacted.
    ///
    /// Aliased hosts are excluded. `~/.ssh/config` owns their identity file, so
    /// the profile's key may well not be the one they present — Portside would
    /// be installing a key on the strength of a guess. `SessionStore.resolved`
    /// skips profiles for aliased hosts for the same reason.
    static func hosts(
        using profile: CredentialProfile,
        in entries: [SessionEntry],
        defaultProfileID: UUID?
    ) -> [SessionEntry] {
        let isDefault = defaultProfileID == profile.id
        return entries.filter { entry in
            guard entry.kind == .host, !entry.usesLocalTransport else { return false }
            guard entry.sshAlias?.isEmpty ?? true else { return false }
            if entry.credentialProfileID == profile.id { return true }
            return isDefault && entry.credentialProfileID == nil
        }
    }

    /// Title for the action, carrying the count so the blast radius is legible
    /// before the sheet opens rather than after.
    static func actionTitle(hostCount: Int) -> String {
        hostCount == 1
            ? "Copy Key to 1 Host Using This Profile…"
            : "Copy Key to \(hostCount) Hosts Using This Profile…"
    }
}
