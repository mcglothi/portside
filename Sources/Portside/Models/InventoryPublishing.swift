import Foundation

/// The pure core of publishing a linked folder to a shared inventory: what
/// goes in the file, how it merges with what's already there, and what must
/// never be committed. No git, no UI — see `InventoryPublisher` for those, and
/// `docs/inventory-publishing-plan.md` for the design.
enum InventoryPublishing {

    // MARK: - Preparing a folder

    /// What publishing a host does to it, said to the person before they send
    /// it — the same sanitizer subscribers apply, so the review shows exactly
    /// what teammates will get.
    struct Note: Equatable, Hashable {
        var host: String
        var text: String
    }

    struct Prepared: Equatable {
        /// Hosts as they'll appear in the manifest: ids are manifest ids,
        /// folders relative to the linked folder.
        var hosts: [SessionEntry]
        var folders: [String]
        var notes: [Note]
    }

    /// The linked folder's hosts, made publishable.
    ///
    /// - `root`: the linked folder; hosts in it and beneath it are published,
    ///   with paths relative to it.
    /// - `manifestIDs`: local id → manifest id for hosts that came from the
    ///   source. Anything not in the map publishes under its own local id,
    ///   which is already a stable UUID.
    static func prepare(entries: [SessionEntry], folders: [String], root: String,
                        manifestIDs: [UUID: UUID] = [:]) -> Prepared {
        let prefix = root.isEmpty ? "" : root + "/"
        func relative(_ path: String) -> String? {
            if path == root { return "" }
            guard root.isEmpty || path.hasPrefix(prefix) else { return nil }
            return String(path.dropFirst(prefix.count))
        }

        var hosts: [SessionEntry] = []
        var notes: [Note] = []
        // The sanitizer derives a per-source id; publishing wants the manifest
        // id itself, so it runs against a fixed throwaway source and the id is
        // put back afterwards.
        let scratch = UUID()
        for entry in entries {
            guard let folder = relative(entry.folder) else { continue }
            var raw = entry
            raw.folder = folder
            guard var clean = SharedManifest.sanitized(raw, sourceID: scratch) else {
                notes.append(Note(host: entry.name,
                                  text: "not published: " + SharedManifest.unshareableReason(entry)))
                continue
            }
            clean.id = manifestIDs[entry.id] ?? entry.id
            hosts.append(clean)
            notes += droppedFields(entry).map { Note(host: entry.name, text: "\($0) left out") }
        }
        let published = folders.compactMap(relative).filter { !$0.isEmpty }
        return Prepared(hosts: LibraryTransfer.sortedForDiff(hosts), folders: Array(Set(published)).sorted(),
                        notes: notes)
    }

    /// Personal settings the sanitizer drops, named for the review.
    static func droppedFields(_ e: SessionEntry) -> [String] {
        var out: [String] = []
        if !(e.runOnConnect ?? "").trimmingCharacters(in: .whitespaces).isEmpty { out.append("run-on-connect") }
        if e.forwardAgent == true { out.append("agent forwarding") }
        if e.forwardX11 == true { out.append("X11 forwarding") }
        if e.credentialProfileID != nil { out.append("credential profile") }
        if e.savePassword { out.append("saved password") }
        if e.isFavorite { out.append("favourite") }
        return out
    }

    // MARK: - Merging

    /// Two people changed the same host differently since the base.
    struct Conflict: Equatable, Identifiable {
        var id: UUID
        /// nil when that side deleted the host.
        var mine: SessionEntry?
        var theirs: SessionEntry?
        var name: String { mine?.name ?? theirs?.name ?? id.uuidString }
    }

    struct Merge: Equatable {
        /// Everything that merged cleanly, plus — for each conflict — whatever
        /// the resolution says (theirs until resolved).
        var hosts: [SessionEntry]
        var folders: [String]
        var conflicts: [Conflict]
    }

    /// Three-way merge by **manifest id**, never by name — so a rename is a
    /// change, not a delete and an add. Per host: whichever side changed it
    /// wins; both changing it the same way is no conflict; both changing it
    /// differently (including one deleting what the other edited) is.
    ///
    /// The reason this is done here rather than left to git: git merges lines,
    /// and two people adding hosts to the same folder in a sorted file
    /// touch adjacent lines — a "conflict" that isn't one. Bruno splits a file
    /// per request for exactly this; owning the merge gets the same result
    /// without changing the manifest format subscribers read.
    static func merge(base: [SessionEntry], mine: [SessionEntry], theirs: [SessionEntry],
                      baseFolders: [String] = [], mineFolders: [String] = [], theirFolders: [String] = [],
                      resolutions: [UUID: Side] = [:]) -> Merge {
        func index(_ list: [SessionEntry]) -> [UUID: SessionEntry] {
            Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        let b = index(base), m = index(mine), t = index(theirs)
        var ids = Set(b.keys).union(m.keys).union(t.keys)
        var out: [SessionEntry] = []
        var conflicts: [Conflict] = []
        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
            let bv = b[id], mv = m[id], tv = t[id]
            let pick: SessionEntry?
            if mv == tv { pick = mv }
            else if mv == bv { pick = tv }
            else if tv == bv { pick = mv }
            else {
                conflicts.append(Conflict(id: id, mine: mv, theirs: tv))
                pick = resolutions[id] == .mine ? mv : tv
            }
            if let pick { out.append(pick) }
        }
        ids.removeAll()

        let fb = Set(baseFolders), fm = Set(mineFolders), ft = Set(theirFolders)
        // Kept if both have it, or one side added it; dropped if one side
        // removed it and the other didn't add it back.
        let folders = fm.union(ft).filter { (fm.contains($0) && ft.contains($0)) || !fb.contains($0) }
        return Merge(hosts: LibraryTransfer.sortedForDiff(out), folders: folders.sorted(), conflicts: conflicts)
    }

    enum Side: String, Codable { case mine, theirs }

    // MARK: - Describing a change

    struct Change: Equatable, Identifiable {
        enum Kind: Equatable { case added, removed, changed }
        var id: UUID
        var kind: Kind
        var name: String
        /// For `.changed`: field, before, after.
        var fields: [FieldChange] = []
    }

    struct FieldChange: Equatable, Hashable {
        var field: String
        var before: String
        var after: String
    }

    /// What publishing `after` would change compared with `before` (the
    /// remote as it stands) — the review sheet's list.
    static func changes(from before: [SessionEntry], to after: [SessionEntry]) -> [Change] {
        let old = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let new = Dictionary(after.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [Change] = []
        for e in after where old[e.id] == nil { out.append(Change(id: e.id, kind: .added, name: e.name)) }
        for e in before where new[e.id] == nil { out.append(Change(id: e.id, kind: .removed, name: e.name)) }
        for e in after {
            guard let o = old[e.id], o != e else { continue }
            out.append(Change(id: e.id, kind: .changed, name: e.name, fields: fieldChanges(o, e)))
        }
        return out.sorted { ($0.name.lowercased(), $0.id.uuidString) < ($1.name.lowercased(), $1.id.uuidString) }
    }

    /// The published fields that differ, in reading order.
    static func fieldChanges(_ a: SessionEntry, _ b: SessionEntry) -> [FieldChange] {
        func s(_ v: String?) -> String { v ?? "" }
        let pairs: [(String, String, String)] = [
            ("name", a.name, b.name),
            ("folder", a.folder, b.folder),
            ("host", a.hostname, b.hostname),
            ("user", s(a.user), s(b.user)),
            ("port", a.port.map(String.init) ?? "", b.port.map(String.init) ?? ""),
            ("ssh alias", s(a.sshAlias), s(b.sshAlias)),
            ("identity file", s(a.identityFile), s(b.identityFile)),
            ("environment", a.environment.rawValue, b.environment.rawValue),
            ("protected", a.isProtected ? "yes" : "no", b.isProtected ? "yes" : "no"),
            ("mosh", a.preferMosh ? "yes" : "no", b.preferMosh ? "yes" : "no"),
            ("keepalive", a.keepAliveSeconds.map(String.init) ?? "", b.keepAliveSeconds.map(String.init) ?? ""),
            ("kind", a.kind.label.lowercased(), b.kind.label.lowercased()),
            ("engine", a.container?.engine.rawValue ?? "", b.container?.engine.rawValue ?? ""),
            ("container", a.container?.name ?? "", b.container?.name ?? ""),
            ("shell", a.container?.shell ?? "", b.container?.shell ?? ""),
            ("container user", a.container?.user ?? "", b.container?.user ?? ""),
        ]
        return pairs.filter { $0.1 != $0.2 }.map { FieldChange(field: $0.0, before: $0.1, after: $0.2) }
    }

    // MARK: - A publish, planned

    /// Everything Publish Changes shows before anything is sent.
    struct Plan {
        var source: InventorySource
        var link: PublishLink
        /// The merge base: the team's version as of the last publish or link.
        var base: [SessionEntry]
        var baseFolders: [String]
        /// The linked folder, prepared.
        var mine: Prepared
        /// The team's version now.
        var theirs: [SessionEntry]
        var theirFolders: [String]
        /// Whether the source's branch exists yet (false: a brand-new repo).
        var remoteBranchExists: Bool

        func merged(_ resolutions: [UUID: Side] = [:]) -> Merge {
            InventoryPublishing.merge(base: base, mine: mine.hosts, theirs: theirs,
                                      baseFolders: baseFolders, mineFolders: mine.folders,
                                      theirFolders: theirFolders, resolutions: resolutions)
        }

        /// What this publish changes on the team's side.
        func changes(_ resolutions: [UUID: Side] = [:]) -> [Change] {
            InventoryPublishing.changes(from: theirs, to: merged(resolutions).hosts)
        }

        /// What the team changed since the base that will come into the
        /// folder — shown so a publish never surprises anyone in either
        /// direction.
        var incoming: [Change] { InventoryPublishing.changes(from: base, to: theirs) }

        var secrets: [Note] { InventoryPublishing.secretFindings(in: mine.hosts, folders: mine.folders) }
    }

    // MARK: - Secrets

    /// Values that look like credentials, which must never be committed.
    ///
    /// The manifest has no field for a secret, but every free-text field can
    /// hold one — a name like `db admin pw hunter2`, a folder pasted from a
    /// URL with a password in it. Insomnia's Git Sync documents that it
    /// doesn't screen for this; publishing refuses instead.
    static func secretFindings(in hosts: [SessionEntry], folders: [String] = []) -> [Note] {
        var out: [Note] = []
        for h in hosts {
            for (field, value) in [("name", h.name), ("folder", h.folder), ("identity file", h.identityFile ?? "")] {
                if let why = secretReason(value) { out.append(Note(host: h.name, text: "\(field) \(why)")) }
            }
        }
        for f in folders {
            if let why = secretReason(f) { out.append(Note(host: f, text: "folder \(why)")) }
        }
        return out
    }

    static func secretReason(_ value: String) -> String? {
        let checks: [(String, String)] = [
            (#"[A-Za-z][A-Za-z0-9+.-]*://[^/\s:@]+:[^@\s]+@"#, "contains a URL with a password in it"),
            (#"-----BEGIN [A-Z ]*PRIVATE KEY-----"#, "contains a private key"),
            (#"\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}"#, "contains a GitHub token"),
            (#"\bgithub_pat_[A-Za-z0-9_]{20,}"#, "contains a GitHub token"),
            (#"\bglpat-[A-Za-z0-9_-]{16,}"#, "contains a GitLab token"),
            (#"\bxox[abprs]-[A-Za-z0-9-]{10,}"#, "contains a Slack token"),
            (#"\bAKIA[0-9A-Z]{16}\b"#, "contains an AWS access key"),
            (#"(?i)\b(password|passwd|pwd|secret|token)\s*[:=]\s*\S+"#, "looks like it contains a password"),
        ]
        for (pattern, why) in checks where value.range(of: pattern, options: .regularExpression) != nil {
            return why
        }
        // A long run of mixed letters, digits and symbols with no spaces is
        // what keys and tokens look like and what names and paths don't.
        for token in value.split(whereSeparator: { $0.isWhitespace || $0 == "/" }) where token.count >= 32 {
            let classes = [token.contains(where: \.isUppercase), token.contains(where: \.isLowercase),
                           token.contains(where: \.isNumber)].filter { $0 }.count
            if classes == 3 && Set(token).count >= 16 { return "contains a long random-looking string" }
        }
        return nil
    }
}
