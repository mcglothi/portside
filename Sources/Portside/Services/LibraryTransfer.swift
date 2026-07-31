import Foundation

/// Portside's own export/import format: a portable JSON snapshot of part of the
/// library, round-tripped through the same Codable models the store persists.
/// Passwords never travel — they live in the Keychain, keyed by session id, and
/// are deliberately left out of exports.
enum LibraryTransfer {
    static let currentVersion = 1

    enum Kind: String, Codable {
        case sessions, macros, library
    }

    struct Document: Codable {
        /// Present (and > 0) only in genuine Portside exports; used to tell an
        /// export apart from a MobaXterm file during import.
        var portsideExport: Int
        var kind: Kind
        var entries: [SessionEntry]?
        var folders: [String]?
        var macros: [Macro]?
        /// Profile *definitions* — name, user, identity file. Never the
        /// secret, which stays in the Keychain keyed by profile id.
        ///
        /// Absent from exports before this was added, which is exactly why a
        /// restored library couldn't authenticate: entries carried a
        /// `credentialProfileID` naming a profile that didn't exist on the
        /// receiving Mac, so the import cleared the reference and switched
        /// saved-password use off for every host. Carrying the definitions
        /// under their original ids is what lets the reference survive the
        /// trip; the password is re-entered once per machine, per profile.
        var credentialProfiles: [CredentialProfile]?
    }

    static func encodeSessions(entries: [SessionEntry], folders: [String],
                               credentialProfiles: [CredentialProfile]) throws -> Data {
        try encode(Document(portsideExport: currentVersion, kind: .sessions,
                            entries: sortedForDiff(entries), folders: folders.sorted(),
                            macros: nil,
                            credentialProfiles: credentialProfiles.sorted { $0.name < $1.name }))
    }

    static func encodeMacros(_ macros: [Macro]) throws -> Data {
        try encode(Document(portsideExport: currentVersion, kind: .macros,
                            entries: nil, folders: nil,
                            macros: macros.sorted { $0.name < $1.name },
                            credentialProfiles: nil))
    }

    /// Stable order so an export diffs cleanly.
    ///
    /// Entries live in the library in insertion order, which means re-exporting
    /// after adding one host can reshuffle the file and bury the real change in
    /// noise. That's tolerable for a one-off export and not tolerable once these
    /// files live in git, so the order is pinned here rather than left to
    /// however the library happens to be arranged. Id breaks ties so the sort is
    /// total — two hosts can legitimately share a folder and a name.
    static func sortedForDiff(_ entries: [SessionEntry]) -> [SessionEntry] {
        entries.sorted {
            ($0.folder, $0.name, $0.hostname, $0.id.uuidString)
                < ($1.folder, $1.name, $1.hostname, $1.id.uuidString)
        }
    }

    /// Returns the parsed export, or nil if `data` isn't a Portside export so
    /// the caller can fall back to MobaXterm parsing.
    static func decode(_ data: Data) -> Document? {
        guard let doc = try? JSONDecoder().decode(Document.self, from: data),
              doc.portsideExport > 0 else { return nil }
        return doc
    }

    private static func encode(_ doc: Document) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(doc)
    }
}
