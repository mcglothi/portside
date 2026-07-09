import Foundation

enum HostEnvironment: String, Codable, CaseIterable, Identifiable {
    case none, prod, staging, dev, personal

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "None"
        case .prod: return "Prod"
        case .staging: return "Staging"
        case .dev: return "Dev"
        case .personal: return "Personal"
        }
    }
}

struct SessionEntry: Identifiable, Hashable {
    enum Source: String, Codable {
        case manual, sshConfig, mobaxterm
    }

    var id = UUID()
    var name: String
    var folder: String = ""          // "" = top level; nested paths use "/", e.g. "prod/web"
    var hostname: String = ""
    var user: String?
    var port: Int?
    var sshAlias: String?            // when set, connect via `ssh <alias>` so ~/.ssh/config rules apply
    var source: Source = .manual
    var environment: HostEnvironment = .none
    var isProtected = false          // excluded from MultiExec unless explicitly confirmed

    var subtitle: String {
        let userPart = user.map { "\($0)@" } ?? ""
        let portPart = port.map { ":\($0)" } ?? ""
        let target = hostname.isEmpty ? (sshAlias ?? "") : hostname
        return userPart + target + portPart
    }

    var sshArgs: [String] {
        if let alias = sshAlias, !alias.isEmpty {
            return [alias]
        }
        var args: [String] = []
        if let port {
            args += ["-p", String(port)]
        }
        args.append(user.map { "\($0)@\(hostname)" } ?? hostname)
        return args
    }

    /// Same target as `sshArgs`, but sftp spells the port flag -P.
    var sftpTargetArgs: [String] {
        if let alias = sshAlias, !alias.isEmpty {
            return [alias]
        }
        var args: [String] = []
        if let port {
            args += ["-P", String(port)]
        }
        args.append(user.map { "\($0)@\(hostname)" } ?? hostname)
        return args
    }
}

// Codable lives in an extension so the memberwise initializer survives;
// decodeIfPresent keeps older library files loading when fields are added.
extension SessionEntry: Codable {
    enum CodingKeys: String, CodingKey {
        case id, name, folder, hostname, user, port, sshAlias, source, environment, isProtected
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        folder = try c.decodeIfPresent(String.self, forKey: .folder) ?? ""
        hostname = try c.decodeIfPresent(String.self, forKey: .hostname) ?? ""
        user = try c.decodeIfPresent(String.self, forKey: .user)
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        sshAlias = try c.decodeIfPresent(String.self, forKey: .sshAlias)
        source = try c.decodeIfPresent(Source.self, forKey: .source) ?? .manual
        environment = try c.decodeIfPresent(HostEnvironment.self, forKey: .environment) ?? .none
        isProtected = try c.decodeIfPresent(Bool.self, forKey: .isProtected) ?? false
    }
}

struct Macro: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var text: String
    var sendReturn = true
}

struct FolderNode: Identifiable {
    var id: String { path }
    let path: String
    let name: String
    var subfolders: [FolderNode]
    var entries: [SessionEntry]
}

enum FolderTree {
    /// Splits entries into top-level entries and a sorted folder hierarchy.
    static func build(entries: [SessionEntry]) -> (root: [SessionEntry], folders: [FolderNode]) {
        let root = entries.filter { $0.folder.isEmpty }.sorted(by: byName)
        let foldered = entries.filter { !$0.folder.isEmpty }
        return (root, childNodes(prefix: "", entries: foldered))
    }

    private static func childNodes(prefix: String, entries: [SessionEntry]) -> [FolderNode] {
        var groups: [String: [SessionEntry]] = [:]
        for entry in entries {
            let remainder = prefix.isEmpty ? entry.folder : String(entry.folder.dropFirst(prefix.count + 1))
            let head = remainder.components(separatedBy: "/").first ?? remainder
            groups[head, default: []].append(entry)
        }
        let names = groups.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return names.map { name in
            let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
            let inGroup = groups[name] ?? []
            let direct = inGroup.filter { $0.folder == path }.sorted(by: byName)
            let deeper = inGroup.filter { $0.folder != path }
            return FolderNode(
                path: path,
                name: name,
                subfolders: childNodes(prefix: path, entries: deeper),
                entries: direct
            )
        }
    }

    private static func byName(_ a: SessionEntry, _ b: SessionEntry) -> Bool {
        a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
}
