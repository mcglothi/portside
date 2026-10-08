import Foundation

/// The wire format between the `portside` CLI (or anything else) and the
/// running app: one JSON object per line on a Unix socket, one response per
/// request. See `docs/agent-api-plan.md`.
///
/// Deliberately boring: no streaming, no subscriptions, no session I/O. Phase
/// one is reading the inventory and opening sessions — the "log me in to
/// everything matching X" case — and nothing that types into a shell.
enum AgentProtocol {
    static let version = 1

    struct Request: Codable, Equatable, Sendable {
        var id: Int?
        var method: String
        var params: Params = Params()

        enum CodingKeys: String, CodingKey { case id, method, params }

        init(id: Int? = nil, method: String, params: Params = Params()) {
            self.id = id
            self.method = method
            self.params = params
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(Int.self, forKey: .id)
            method = try c.decode(String.self, forKey: .method)
            params = try c.decodeIfPresent(Params.self, forKey: .params) ?? Params()
        }
    }

    /// Every method's parameters in one flat bag. Unknown keys are ignored, so
    /// a newer CLI talking to an older app degrades rather than failing.
    struct Params: Codable, Equatable, Sendable {
        /// A host filter in the sidebar's syntax: `env:prod folder:web -is:protected`.
        var query: String?
        /// Explicit host, group or tab ids, as returned by a listing.
        var ids: [String]?
        /// A group or tab by name (case-insensitive), for `open-group`/`focus`.
        var name: String?
        /// `tabs` (one per host, the default) or `grid` (one tab, split).
        var layout: String?
        /// A pane, by id (from `tabs`), by host name when only one pane shows
        /// that host, or `current` for the one the user is looking at — for
        /// `send`, `screen` and `last-command`.
        var pane: String?
        /// Text to type, for `send`. Control characters are dropped; a
        /// newline is Return.
        var text: String?
        /// Press Return after the text.
        var enter: Bool?
        /// A single key instead of text: enter, tab, escape, ctrl-c, ctrl-d.
        var key: String?
        /// How many lines of the pane to return, for `screen`.
        var lines: Int?
        /// How many recent commands to return, for `last-command`.
        var count: Int?
        /// Seconds to wait before answering: for `last-command`, until a
        /// command finishes that hadn't when asked; for `connect`, until the
        /// opened sessions are connected (or have failed). Capped at 120.
        var wait: Int?
    }

    struct Response: Codable, Sendable {
        var id: Int?
        var result: JSONValue?
        var error: Failure?
    }

    struct Failure: Codable, Equatable, Error, Sendable {
        var code: String
        var message: String

        static func badRequest(_ m: String) -> Failure { Failure(code: "bad_request", message: m) }
        static func denied(_ m: String) -> Failure { Failure(code: "denied", message: m) }
        static func notFound(_ m: String) -> Failure { Failure(code: "not_found", message: m) }
        static let declined = Failure(code: "declined", message: "Declined in Portside.")
        static let timedOut = Failure(code: "timed_out",
                                      message: "Nobody answered the confirmation in Portside in time.")
    }

    /// What a method can do, from least to most. A client is granted a tier,
    /// and a tier includes everything below it — kitty's per-password action
    /// lists, collapsed to the three levels that actually differ in risk.
    enum Tier: Int, Codable, Comparable, CaseIterable {
        /// List hosts, groups and tabs. No side effects.
        case read = 1
        /// Open sessions and groups, focus and close tabs.
        case open = 2
        /// Type into a session and read its screen. Only grantable while
        /// "Allow agents to type into sessions" is on.
        case input = 3

        static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }

        var label: String {
            switch self {
            case .read: return "Read only"
            case .open: return "Read and open sessions"
            case .input: return "Read, open and type"
            }
        }
    }

    enum Method: String, CaseIterable {
        case status, hosts, groups, tabs
        case connect, openGroup = "open-group", focus, close
        case send, screen, lastCommand = "last-command"

        var tier: Tier {
            switch self {
            case .status, .hosts, .groups, .tabs: return .read
            case .connect, .openGroup, .focus, .close: return .open
            case .send, .screen, .lastCommand: return .input
            }
        }
    }
}

/// A minimal JSON tree, so results can be built without a Codable type per
/// method and printed by a CLI that shares no code with the app.
enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), null
    case array([JSONValue]), object([String: JSONValue])

    init(_ s: String?) { self = s.map(JSONValue.string) ?? .null }
    init(_ i: Int) { self = .number(Double(i)) }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n):
            if n == n.rounded(), abs(n) < 1e15 { try c.encode(Int(n)) } else { try c.encode(n) }
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
}

/// The decisions that don't depend on any UI, kept here so they can be tested
/// without a socket, a window, or a person to click.
enum AgentPolicy {
    /// Default for "opening more than this many hosts at once asks first".
    static let defaultConnectCap = 20

    /// Why a connect has to be confirmed by a person in the app, or nil when
    /// it can go ahead. The same two checks a human gets — protected hosts are
    /// never opened without someone seeing their names — plus a count cap that
    /// a human doesn't need, because a human doesn't type `/.*/` by accident.
    static func connectConfirmation(for hosts: [SessionEntry], cap: Int) -> String? {
        var reasons: [String] = []
        let protected = hosts.filter(\.isProtected)
        if !protected.isEmpty {
            let names = protected.prefix(8).map(\.name).joined(separator: ", ")
            let more = protected.count > 8 ? " and \(protected.count - 8) more" : ""
            reasons.append("\(protected.count) protected host\(protected.count == 1 ? "" : "s"): \(names)\(more)")
        }
        if hosts.count > cap {
            reasons.append("\(hosts.count) hosts, more than the \(cap) allowed without asking")
        }
        return reasons.isEmpty ? nil : reasons.joined(separator: "; ")
    }

    /// The hosts a connect means: explicit ids win, else the query; an empty
    /// or all-negative query is refused rather than meaning "everything".
    static func selectHosts(_ params: AgentProtocol.Params, from entries: [SessionEntry],
                            profileNames: [UUID: String]) -> Result<[SessionEntry], AgentProtocol.Failure> {
        if let ids = params.ids, !ids.isEmpty {
            let wanted = Set(ids.compactMap { UUID(uuidString: $0) })
            guard wanted.count == ids.count else { return .failure(.badRequest("Not every id is a UUID.")) }
            let found = entries.filter { wanted.contains($0.id) }
            guard found.count == wanted.count else {
                return .failure(.notFound("\(wanted.count - found.count) of those ids aren't in the library."))
            }
            return .success(found)
        }
        let text = params.query?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !text.isEmpty else {
            return .failure(.badRequest("Give a query or ids. An empty selection would mean every host."))
        }
        let query = HostQuery(text)
        if !query.invalidPatterns.isEmpty {
            return .failure(.badRequest("Invalid pattern: \(query.invalidPatterns.joined(separator: ", "))"))
        }
        let matched = entries.filter { query.matches($0, profileNames: profileNames) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !matched.isEmpty else { return .failure(.notFound("No hosts match \u{201C}\(text)\u{201D}.")) }
        return .success(matched)
    }

    /// What `send` will actually type: control characters dropped (an agent
    /// can't smuggle escape sequences or ^D into a shell through text), a
    /// newline becomes Return, and a named key stands alone.
    static func keystrokes(text: String?, enter: Bool, key: String?) -> Result<String, AgentProtocol.Failure> {
        if let key {
            let keys: [String: String] = ["enter": "\r", "return": "\r", "tab": "\t", "escape": "\u{1B}",
                                          "ctrl-c": "\u{3}", "ctrl-d": "\u{4}"]
            guard let k = keys[key.lowercased()] else {
                return .failure(.badRequest("Unknown key \u{201C}\(key)\u{201D}. Use enter, tab, escape, ctrl-c or ctrl-d."))
            }
            return .success(k)
        }
        guard let text, !text.isEmpty else { return .failure(.badRequest("Give text or a key.")) }
        var out = ""
        for scalar in text.unicodeScalars {
            if scalar == "\n" || scalar == "\r" { out += "\r" }
            else if scalar == "\t" { out += "\t" }
            else if !CharacterSet.controlCharacters.contains(scalar) { out.unicodeScalars.append(scalar) }
        }
        if enter && !out.hasSuffix("\r") { out += "\r" }
        guard !out.isEmpty else { return .failure(.badRequest("Nothing left to type once control characters were removed.")) }
        return .success(out)
    }

    /// Whether the last line on screen is asking for a secret. Used only to
    /// *refuse* typing, so it leans towards yes.
    static func looksLikeSecretPrompt(_ lastLine: String) -> Bool {
        let line = lastLine.trimmingCharacters(in: .whitespaces).lowercased()
        guard !line.isEmpty, line.count < 200 else { return false }
        let words = ["password", "passphrase", "passcode", "verification code", "one-time code", "otp",
                     "pin:", "token:", "secret:", "[sudo]"]
        return words.contains { line.contains($0) } && (line.hasSuffix(":") || line.hasSuffix("?")
            || line.hasSuffix(">") || line.contains("[sudo]"))
    }

    /// Screen text for an agent: plain text, no control characters, at most
    /// `limit` trailing lines with trailing blank lines dropped.
    static func screenText(_ raw: String, lines limit: Int) -> String {
        var rows = raw.components(separatedBy: "\n").map { line in
            String(line.unicodeScalars.filter { $0 == "\t" || !CharacterSet.controlCharacters.contains($0) })
                .replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }
        while rows.last?.isEmpty == true { rows.removeLast() }
        return rows.suffix(max(1, limit)).joined(separator: "\n")
    }

    /// A shared or local host as a listing row. Never carries a password,
    /// a key's contents, or anything from the Keychain.
    static func hostRow(_ e: SessionEntry, source: String?) -> JSONValue {
        .object([
            "id": .string(e.id.uuidString),
            "name": .string(e.name),
            "folder": .string(e.folder),
            "source": JSONValue(source),
            "kind": .string(e.kind.rawValue),
            "target": .string(e.subtitle),
            "environment": .string(e.environment.rawValue),
            "protected": .bool(e.isProtected),
            "favorite": .bool(e.isFavorite),
        ])
    }
}
