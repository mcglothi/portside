import CryptoKit
import Foundation

/// A team's host inventory, published to a git repository and subscribed to
/// read-only. See `docs/shared-inventory-plan.md`, phase 4.
///
/// Shared hosts appear *alongside* the user's own library, never instead of
/// it, and nothing about a source is ever written back: Portside clones,
/// fast-forwards, and reads one file. No forge API, no account — the remote is
/// any URL `git` itself can reach, authenticated by whatever the user's git
/// already uses.
struct InventorySource: Identifiable, Codable, Equatable {
    var id = UUID()
    /// Shown as the source's root in the sidebar: "Platform Team".
    var name: String
    /// Any git URL: `git@host:team/inventory.git`, `ssh://…`, `https://…`, or
    /// a local path.
    var remote: String
    var ref: String = "main"
    /// The manifest within the repository — a Portside sessions export.
    var path: String = "portside.json"

    init(id: UUID = UUID(), name: String, remote: String, ref: String = "main",
         path: String = "portside.json") {
        self.id = id
        self.name = name
        self.remote = remote
        self.ref = ref
        self.path = path
    }

    enum CodingKeys: String, CodingKey { case id, name, remote, ref, path }

    // Tolerant for the reason spelled out on `Macro`: a field added later must
    // not make an older library fail to load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        remote = try c.decode(String.self, forKey: .remote)
        ref = try c.decodeIfPresent(String.self, forKey: .ref) ?? "main"
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? "portside.json"
    }

    /// Why this source can't be used as written, or nil when it can.
    ///
    /// Each value reaches `git` as an argument, so the rule that kept
    /// `ssh://-oProxyCommand=…` out of `ConnectionLink` applies here too:
    /// nothing may start with `-`, where git would read it as an option.
    var validationProblem: String? {
        let remote = remote.trimmingCharacters(in: .whitespaces)
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give the source a name." }
        if remote.isEmpty { return "Enter the repository's git URL." }
        if remote.hasPrefix("-") || Self.hasControlCharacters(remote) {
            return "That isn't a usable git URL."
        }
        // git's ext:: transport runs a command named in the URL. It is off by
        // default in modern git, and refused here regardless.
        if remote.lowercased().hasPrefix("ext::") { return "ext:: remotes run commands and aren't allowed." }
        if ref.isEmpty || ref.hasPrefix("-") || ref.contains("..")
            || ref.contains(where: { $0.isWhitespace }) || Self.hasControlCharacters(ref) {
            return "That isn't a usable branch or tag name."
        }
        if Self.normalizedManifestPath(path) == nil {
            return "The manifest path must be a file inside the repository."
        }
        return nil
    }

    /// The manifest path as components inside the clone, or nil if it would
    /// leave it — absolute, `..`, or empty.
    static func normalizedManifestPath(_ path: String) -> [String]? {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !hasControlCharacters(trimmed) else { return nil }
        let parts = trimmed.split(separator: "/").map(String.init).filter { $0 != "." }
        guard !parts.isEmpty, !parts.contains("..") else { return nil }
        return parts
    }

    static func hasControlCharacters(_ s: String) -> Bool {
        s.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

/// What the user has said about a shared host for themselves.
///
/// A shared entry is read-only from its source, but people still need their
/// own credential profile, a favourite star, and — most of all — the ability to
/// mark a host protected without a pull request to the team's repo. Protection
/// is a local safety judgement. Everything else about the host comes from the
/// source and changes when it's pulled.
struct SharedOverlay: Codable, Equatable {
    /// The shared host's id as Portside sees it — `SharedManifest.entryID`,
    /// not the id in the manifest.
    var entryID: UUID
    /// Replaces the source's environment when set.
    var environment: HostEnvironment?
    /// Protected if the source *or* the user says so. A user can add
    /// protection to a shared host; they can't take away the team's.
    var isProtected = false
    var isFavorite = false
    var credentialProfileID: UUID?
    var savePassword = false
    var runOnConnect: String?
    var forwardAgent: Bool?
    var forwardX11: Bool?

    init(entryID: UUID) { self.entryID = entryID }

    var isEmpty: Bool { self == SharedOverlay(entryID: entryID) }

    enum CodingKeys: String, CodingKey {
        case entryID, environment, isProtected, isFavorite, credentialProfileID
        case savePassword, runOnConnect, forwardAgent, forwardX11
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entryID = try c.decode(UUID.self, forKey: .entryID)
        environment = try c.decodeIfPresent(HostEnvironment.self, forKey: .environment)
        isProtected = try c.decodeIfPresent(Bool.self, forKey: .isProtected) ?? false
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        credentialProfileID = try c.decodeIfPresent(UUID.self, forKey: .credentialProfileID)
        savePassword = try c.decodeIfPresent(Bool.self, forKey: .savePassword) ?? false
        runOnConnect = try c.decodeIfPresent(String.self, forKey: .runOnConnect)
        forwardAgent = try c.decodeIfPresent(Bool.self, forKey: .forwardAgent)
        forwardX11 = try c.decodeIfPresent(Bool.self, forKey: .forwardX11)
    }

    /// The host as this user connects to it.
    func applied(to shared: SessionEntry) -> SessionEntry {
        var e = shared
        if let environment { e.environment = environment }
        e.isProtected = shared.isProtected || isProtected
        e.isFavorite = isFavorite
        e.credentialProfileID = credentialProfileID
        e.savePassword = savePassword
        e.runOnConnect = runOnConnect
        e.forwardAgent = forwardAgent
        e.forwardX11 = forwardX11
        return e
    }
}

/// Reading a source's manifest into hosts that are safe to show and connect.
///
/// The manifest is somebody else's file, arriving by `git pull`, and anything
/// in it reaches `ssh` the moment the user double-clicks. So it is read the
/// way `ConnectionLink` reads a URL — strictly — and narrowed to what a team
/// inventory is for: *where* hosts are. Anything that would act on this Mac or
/// on the user's behalf is dropped:
///
/// - **SSH hosts, and containers on them.** A container reached over SSH is
///   a host plus which container: its exec is rebuilt from fields held to
///   what they can legitimately be (`sharedContainer`), never taken as a
///   command. A container on this Mac would run its engine here, Kubernetes
///   brings a local kubeconfig and credential plugins, and a serial session
///   opens a device on this Mac — none of those are shared.
/// - **No run-on-connect.** It types a command into the session as the user.
/// - **No agent or X11 forwarding.** Either one hands the remote host a way
///   back into this machine; that's the user's call, made in their overlay.
/// - **No credential profile, saved password or favourite.** Profile ids name
///   profiles on the publisher's Mac, and the rest is personal.
/// - Host, alias and user are held to the characters they can legitimately
///   contain, and none may start with `-`, which ssh would read as an option.
enum SharedManifest {
    struct Parsed: Equatable {
        var entries: [SessionEntry]
        var folders: [String]
        /// Records present in the file but not shown: unreadable, not
        /// something that can be shared, or carrying a value that isn't safe
        /// to hand to ssh.
        var skipped: Int
    }

    enum ParseError: LocalizedError, Equatable {
        case notAManifest
        var errorDescription: String? {
            "The manifest isn't a Portside sessions export (File \u{25B8} Export Sessions\u{2026})."
        }
    }

    private struct Document: Decodable {
        var entries: LenientArray<SessionEntry>?
        var folders: [String]?
        /// A raw `portside.json` library rather than an export.
        var explicitFolders: [String]?

        enum CodingKeys: String, CodingKey { case entries, folders, explicitFolders }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            entries = try c.decodeIfPresent(LenientArray<SessionEntry>.self, forKey: .entries)
            folders = try? c.decodeIfPresent([String].self, forKey: .folders)
            explicitFolders = try? c.decodeIfPresent([String].self, forKey: .explicitFolders)
        }
    }

    /// Counts what the lenient array drops so the total can be reported.
    private struct RawCount: Decodable {
        var entries: [Discard]?
        struct Discard: Decodable { init(from decoder: Decoder) throws {} }
    }

    static func parse(_ data: Data, sourceID: UUID) throws -> Parsed {
        guard let doc = try? JSONDecoder().decode(Document.self, from: data),
              let decoded = doc.entries?.elements else { throw ParseError.notAManifest }
        let total = (try? JSONDecoder().decode(RawCount.self, from: data))?.entries?.count ?? decoded.count

        var seen = Set<UUID>()
        var entries: [SessionEntry] = []
        for raw in decoded {
            // A hand-edited manifest can repeat an id; the first one wins
            // rather than two rows sharing an identity.
            guard seen.insert(raw.id).inserted, let entry = sanitized(raw, sourceID: sourceID) else { continue }
            entries.append(entry)
        }
        let folders = (doc.folders ?? []) + (doc.explicitFolders ?? [])
        return Parsed(entries: entries,
                      folders: Array(Set(folders.compactMap(normalizedFolder).filter { !$0.isEmpty })).sorted(),
                      skipped: total - entries.count)
    }

    /// The id a shared host has in *this* Portside: derived from the source and
    /// the manifest's id, so it is stable across pulls — which is what lets
    /// recents, history, groups, saved passwords and overlays keep pointing at
    /// it — and distinct when the same repository is subscribed twice.
    static func entryID(sourceID: UUID, manifestID: UUID) -> UUID {
        let digest = SHA256.hash(data: Data("portside-shared:\(sourceID.uuidString):\(manifestID.uuidString)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50 // version 5 shape: name-based
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static func sanitized(_ raw: SessionEntry, sourceID: UUID) -> SessionEntry? {
        var container: ContainerTarget?
        switch raw.kind {
        case .host: break
        case .container:
            guard let target = sharedContainer(raw.container) else { return nil }
            container = target
        default: return nil
        }
        func clean(_ s: String?) -> String? {
            let t = s?.trimmingCharacters(in: .whitespaces) ?? ""
            return t.isEmpty ? nil : t
        }
        let hostname = clean(raw.hostname)
        let alias = clean(raw.sshAlias)
        let user = clean(raw.user)
        guard hostname != nil || alias != nil else { return nil }
        if let hostname, !ConnectionLink.isSafeHost(hostname) { return nil }
        if let alias, !ConnectionLink.isSafeHost(alias) { return nil }
        if let user, !ConnectionLink.isSafeUser(user) { return nil }
        if let key = clean(raw.identityFile), InventorySource.hasControlCharacters(key) { return nil }
        // A container without a host would exec on this Mac. The check above
        // already demands a host or alias; this says why it matters here.
        if container != nil, hostname == nil, alias == nil { return nil }

        let name = String(raw.name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespaces)
        var entry = SessionEntry(name: name.isEmpty ? (hostname ?? alias ?? "") : name,
                                 folder: normalizedFolder(raw.folder) ?? "",
                                 hostname: hostname ?? "")
        entry.id = entryID(sourceID: sourceID, manifestID: raw.id)
        entry.user = user
        entry.sshAlias = alias
        entry.port = raw.port.flatMap { (1...65535).contains($0) ? $0 : nil }
        entry.identityFile = clean(raw.identityFile)
        entry.environment = raw.environment
        entry.isProtected = raw.isProtected
        entry.preferMosh = raw.preferMosh
        entry.keepAliveSeconds = raw.keepAliveSeconds.flatMap { (1...3600).contains($0) ? $0 : nil }
        if let container {
            entry.kind = .container
            entry.container = container
        }
        return entry
    }

    /// Why `entry` can't be shared, for the publish review.
    static func unshareableReason(_ entry: SessionEntry) -> String {
        switch entry.kind {
        case .host:
            return "its host, alias or user can\u{2019}t be passed to ssh safely"
        case .container where entry.usesLocalTransport:
            return "this container runs on this Mac; only a container on an SSH host can be shared"
        case .container:
            return "its container, shell or user isn\u{2019}t a plain name, or its host can\u{2019}t be "
                + "passed to ssh safely"
        default:
            return "only SSH hosts and containers on them can be shared (this is "
                + "\(entry.kind.label.lowercased()))"
        }
    }

    /// A shared container's target, or nil if any field is more than a name.
    ///
    /// Subscribers' Portside types `<engine> exec -it [-u user] <name> <shell>`
    /// into the remote shell as them, so each field is held to the shape it
    /// has in practice: a container name as docker allows one, a user or
    /// `uid:gid`, and a shell from a short list (optionally with its usual
    /// path). Quoting already keeps a value from becoming a second command;
    /// this also keeps the *one* command from being anything but a shell —
    /// `shell: "/tmp/payload"` would otherwise be a fine-looking exec.
    static func sharedContainer(_ target: ContainerTarget?) -> ContainerTarget? {
        guard let target else { return nil }
        let name = target.name.trimmingCharacters(in: .whitespaces)
        let shell = target.shell.trimmingCharacters(in: .whitespaces)
        let user = target.user.trimmingCharacters(in: .whitespaces)
        guard matches(name, #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,254}$"#),
              shell.isEmpty || isPlainShell(shell),
              user.isEmpty || matches(user, #"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}(:[A-Za-z0-9_][A-Za-z0-9_.-]{0,63})?$"#)
        else { return nil }
        return ContainerTarget(engine: target.engine, name: name, shell: shell.isEmpty ? "sh" : shell, user: user)
    }

    static let plainShells: Set<String> = ["sh", "bash", "ash", "dash", "zsh", "ksh", "mksh", "fish"]

    static func isPlainShell(_ shell: String) -> Bool {
        for dir in ["", "/bin/", "/usr/bin/", "/usr/local/bin/"] where shell.hasPrefix(dir) {
            if plainShells.contains(String(shell.dropFirst(dir.count))) { return true }
        }
        return false
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    /// A folder path with empty, `.`, `..` and control-character segments
    /// removed. nil only for input that is nothing but those.
    static func normalizedFolder(_ path: String) -> String? {
        let parts = path.split(separator: "/")
            .map { String($0.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
                .trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        return parts.joined(separator: "/")
    }
}

/// Where one subscribed source stands on this Mac. Machine state, never
/// persisted: it is rebuilt from the local clone at launch and refreshed by a
/// pull, so a source is readable offline exactly as it was last fetched.
struct SharedInventoryState: Equatable {
    /// Sanitized hosts with Portside ids, before any overlay.
    var entries: [SessionEntry] = []
    var folders: [String] = []
    var skipped = 0
    var commit: String?
    var lastSynced: Date?
    /// The last pull's failure. The previous good contents stay in place —
    /// a source going offline shouldn't empty the sidebar.
    var error: String?
    var isSyncing = false
}


/// A local folder that publishes to a subscribed source — the write half of
/// shared inventory. The folder is the user's own, edited as usual; the
/// source's root stays the team's read-only view of what's merged. See
/// `docs/inventory-publishing-plan.md`.
struct PublishLink: Codable, Equatable, Identifiable {
    var id: UUID { sourceID }
    var sourceID: UUID
    /// The local folder whose subtree is published, paths made relative to it.
    var folder: String
    /// Opt-in: push straight to the source's branch instead of a review branch.
    var directPush = false
    /// Local id → manifest id, for hosts that came from the source. Kept as
    /// strings so the file stays readable JSON rather than a pair array.
    var manifestIDStrings: [String: String] = [:]

    init(sourceID: UUID, folder: String, directPush: Bool = false) {
        self.sourceID = sourceID
        self.folder = folder
        self.directPush = directPush
    }

    var manifestIDs: [UUID: UUID] {
        get {
            Dictionary(manifestIDStrings.compactMap { k, v in
                UUID(uuidString: k).flatMap { key in UUID(uuidString: v).map { (key, $0) } }
            }, uniquingKeysWith: { a, _ in a })
        }
        set { manifestIDStrings = Dictionary(newValue.map { ($0.key.uuidString, $0.value.uuidString) },
                                             uniquingKeysWith: { a, _ in a }) }
    }

    enum CodingKeys: String, CodingKey { case sourceID, folder, directPush, manifestIDStrings }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceID = try c.decode(UUID.self, forKey: .sourceID)
        folder = try c.decode(String.self, forKey: .folder)
        directPush = try c.decodeIfPresent(Bool.self, forKey: .directPush) ?? false
        manifestIDStrings = try c.decodeIfPresent([String: String].self, forKey: .manifestIDStrings) ?? [:]
    }
}

extension SharedManifest {
    /// A manifest read for *publishing*: sanitized exactly as subscribers read
    /// it, but keeping the manifest's own ids rather than per-source ones —
    /// those are what a three-way merge matches on.
    static func parseKeepingIDs(_ data: Data) throws -> Parsed {
        let scratch = UUID()
        var parsed = try parse(data, sourceID: scratch)
        // `parse` derived each id from (scratch, manifest id); undo that by
        // pairing in the original order of the surviving records.
        struct Raw: Decodable { var entries: LenientArray<SessionEntry>? }
        let raw = (try? JSONDecoder().decode(Raw.self, from: data))?.entries?.elements ?? []
        let byDerived = Dictionary(raw.map { (entryID(sourceID: scratch, manifestID: $0.id), $0.id) },
                                   uniquingKeysWith: { a, _ in a })
        for i in parsed.entries.indices {
            if let original = byDerived[parsed.entries[i].id] { parsed.entries[i].id = original }
        }
        return parsed
    }
}
