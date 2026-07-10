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
    }

    static func encodeSessions(entries: [SessionEntry], folders: [String]) throws -> Data {
        try encode(Document(portsideExport: currentVersion, kind: .sessions,
                            entries: entries, folders: folders, macros: nil))
    }

    static func encodeMacros(_ macros: [Macro]) throws -> Data {
        try encode(Document(portsideExport: currentVersion, kind: .macros,
                            entries: nil, folders: nil, macros: macros))
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
