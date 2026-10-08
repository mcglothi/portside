import Foundation

/// An `ssh://` or `portside://` link handed to Portside by macOS — from a
/// wiki, a Grafana panel, a CMDB, or `open` in a script.
///
/// Links come from anywhere, so parsing is strict rather than forgiving. The
/// classic hole in ssh URL handlers is a host like `-oProxyCommand=…`, which
/// reaches ssh as an *option* and runs a command; nothing here can start with
/// `-`, and user and host are held to the characters they can legitimately
/// contain, so a value either is a plain name/address or is refused.
enum ConnectionLink: Equatable {
    /// `ssh://[user@]host[:port]`
    case ssh(user: String?, host: String, port: Int?)
    /// `portside://connect/<name>` — a saved host or alias, by name.
    case named(String)

    enum ParseError: LocalizedError, Equatable {
        case unsupported(String)
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .unsupported(let what): return "Portside doesn't open \(what) links."
            case .invalid(let why): return why
            }
        }
    }

    static func parse(_ url: URL) throws -> ConnectionLink {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased() else {
            throw ParseError.invalid("The link isn't a well-formed URL.")
        }
        switch scheme {
        case "ssh":
            // percentEncodedHost keeps an IPv6 literal's brackets; strip them.
            var host = components.percentEncodedHost ?? ""
            if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
            guard isSafeHost(host) else {
                // Validate the encoded form (a % never passes), but show what
                // the link meant: "my%20host" reads as "my host".
                throw ParseError.invalid("The link's host “\(readable(host))” isn't a valid host name or address.")
            }
            let user = components.user?.removingPercentEncoding
            if let user, !isSafeUser(user) {
                throw ParseError.invalid("The link's user name “\(user)” isn't valid.")
            }
            if let port = components.port, !(1...65535).contains(port) {
                throw ParseError.invalid("The link's port \(port) is out of range.")
            }
            return .ssh(user: user?.isEmpty == true ? nil : user, host: host, port: components.port)

        case "portside":
            guard components.host?.lowercased() == "connect" else {
                throw ParseError.unsupported("portside://\(components.host ?? "")")
            }
            let name = components.path
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .removingPercentEncoding ?? ""
            guard !name.isEmpty else {
                throw ParseError.invalid("The link doesn't name a host — use portside://connect/<name>.")
            }
            return .named(name)

        default:
            throw ParseError.unsupported("\(scheme)://")
        }
    }

    /// The saved host this link means, if any. A link spelling out a user or
    /// port only matches a host that agrees, so `ssh://root@web01` doesn't
    /// quietly open a saved `deploy@web01`.
    func match(in entries: [SessionEntry]) -> SessionEntry? {
        let hosts = entries.filter { $0.kind == .host }
        func same(_ a: String?, _ b: String) -> Bool {
            a?.caseInsensitiveCompare(b) == .orderedSame
        }
        switch self {
        case .named(let name):
            return hosts.first { same($0.name, name) }
                ?? hosts.first { same($0.sshAlias, name) }
                ?? hosts.first { same($0.hostname, name) }
        case .ssh(let user, let host, let port):
            return hosts.first { entry in
                guard same(entry.hostname, host) || same(entry.sshAlias, host) || same(entry.name, host)
                else { return false }
                if let user, entry.user != nil, entry.user != user { return false }
                if let port, (entry.port ?? 22) != port { return false }
                return true
            }
        }
    }

    /// An unsaved host to connect to (or save). Only meaningful for `.ssh`.
    var adHocEntry: SessionEntry? {
        guard case .ssh(let user, let host, let port) = self else { return nil }
        var entry = SessionEntry(name: host, folder: "", hostname: host)
        entry.user = user
        entry.port = port
        return entry
    }

    var displayTarget: String {
        switch self {
        case .named(let name): return name
        case .ssh(let user, let host, let port):
            return (user.map { "\($0)@" } ?? "") + host + (port.map { ":\($0)" } ?? "")
        }
    }

    /// A rejected host as a person would read it: percent-decoded, with any
    /// control characters a hostile link smuggled in dropped from the alert.
    private static func readable(_ host: String) -> String {
        let decoded = host.removingPercentEncoding ?? host
        return String(decoded.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
    }

    static func isSafeHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253, !host.hasPrefix("-") else { return false }
        return host.unicodeScalars.allSatisfy { safeHostCharacters.contains($0) }
    }

    static func isSafeUser(_ user: String) -> Bool {
        guard user.count <= 64, !user.hasPrefix("-") else { return false }
        return user.unicodeScalars.allSatisfy { safeUserCharacters.contains($0) }
    }

    // Letters, digits, dot, hyphen, underscore; colon for IPv6.
    private static let safeHostCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:_")
    // POSIX portable user names, plus the domain separators AD logins carry.
    private static let safeUserCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-\\")
}
