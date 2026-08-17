import Foundation

/// Somewhere in the local library that still names the key about to be retired.
struct RetiredKeyReference: Equatable, Identifiable {
    enum Source: Equatable {
        /// A host's own `identityFile`.
        case host(String)
        /// A credential profile's `identityFile` — which stands for every host
        /// deferring to it, so one of these is worth more than one host.
        case profile(String)
        /// The library-wide default key.
        case libraryDefault
    }

    let source: Source
    /// The path as configured, before tilde expansion, so the message says what
    /// the user will actually see when they go and look.
    let path: String

    var id: String {
        switch source {
        case .host(let name): return "host:\(name)"
        case .profile(let name): return "profile:\(name)"
        case .libraryDefault: return "default"
        }
    }

    var label: String {
        switch source {
        case .host(let name): return name
        case .profile(let name): return "\(name) (credential profile)"
        case .libraryDefault: return "Library default key"
        }
    }
}

/// Finds local configuration still pointing at a key that is about to stop
/// working.
///
/// ## Why this exists
///
/// Retiring a key changes the **host**. It does not change the *pointer* on this
/// Mac that tells ssh to offer that key. Those are two different things, and a
/// rotation that does the first without mentioning the second hands someone a
/// host that no longer accepts the only key their config offers it.
///
/// Portside cannot simply fix them all, which is why this reports rather than
/// repairs:
///
/// - It **can** see a host's own `identityFile`, a credential profile's, and the
///   library default, because it owns those.
/// - It **cannot** see `~/.ssh/config`, which is where an aliased host's
///   `IdentityFile` lives — and aliased hosts are the common case. Rewriting
///   someone's ssh config is also not a thing to do quietly.
///
/// So the retirement confirmation names what it can find and says plainly that
/// `~/.ssh/config` may name the key too.
enum KeyRotationReferences {

    /// Everything in the library still naming `key`.
    ///
    /// Only the hosts passed in are considered — the ones actually losing the
    /// key — plus profiles and defaults, which are library-wide and therefore
    /// relevant however narrow the rotation was.
    static func references(
        to key: PublicKey,
        hosts: [SessionEntry],
        profiles: [CredentialProfile],
        defaults: ConnectionDefaults
    ) -> [RetiredKeyReference] {
        var found: [RetiredKeyReference] = []

        for host in hosts {
            if let path = host.identityFile, names(key, path) {
                found.append(RetiredKeyReference(source: .host(host.name), path: path))
            }
        }
        for profile in profiles {
            if let path = profile.identityFile, names(key, path) {
                found.append(RetiredKeyReference(source: .profile(profile.name), path: path))
            }
        }
        if let path = defaults.identityFile, names(key, path) {
            found.append(RetiredKeyReference(source: .libraryDefault, path: path))
        }
        return found
    }

    /// Whether a configured `identityFile` refers to this key.
    ///
    /// `identityFile` is a **private** key path and a `PublicKey` knows its
    /// `.pub`, so both ends are normalised to the private form before
    /// comparing — and a profile pointing straight at the `.pub` is tolerated,
    /// because `CredentialProfileKey` already documents that people do that.
    static func names(_ key: PublicKey, _ configuredPath: String) -> Bool {
        let configured = normalise(configuredPath)
        guard !configured.isEmpty else { return false }
        return configured == normalise(key.path)
    }

    private static func normalise(_ path: String) -> String {
        var value = path.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return "" }
        value = (value as NSString).expandingTildeInPath
        if value.hasSuffix(".pub") { value = String(value.dropLast(4)) }
        return (value as NSString).standardizingPath
    }

    /// The sentence shown when nothing local was found — because "nothing
    /// found" is not the same as "nothing points at it", and the difference is
    /// an aliased host whose key lives in a file Portside never reads.
    static let sshConfigCaveat =
        "Portside can't see ~/.ssh/config. If an aliased host names this key there with "
        + "IdentityFile, update it by hand — retiring the key doesn't change that line."
}
