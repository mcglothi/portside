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
    var identityFile: String?        // private key path; passed as `ssh -i`
    var savePassword = false         // password stored in the Keychain under this id
    var source: Source = .manual
    var environment: HostEnvironment = .none
    var isProtected = false          // excluded from MultiExec unless explicitly confirmed
    var runOnConnect: String?        // command sent to the shell shortly after connecting

    var subtitle: String {
        let userPart = user.map { "\($0)@" } ?? ""
        let portPart = port.map { ":\($0)" } ?? ""
        let target = hostname.isEmpty ? (sshAlias ?? "") : hostname
        return userPart + target + portPart
    }

    private var identityArgs: [String] {
        guard let path = identityFile, !path.isEmpty else { return [] }
        return ["-i", (path as NSString).expandingTildeInPath]
    }

    var sshArgs: [String] {
        if let alias = sshAlias, !alias.isEmpty {
            return identityArgs + [alias]
        }
        var args = identityArgs
        if let port {
            args += ["-p", String(port)]
        }
        args.append(user.map { "\($0)@\(hostname)" } ?? hostname)
        return args
    }

    /// Same target as `sshArgs`, but sftp spells the port flag -P.
    var sftpTargetArgs: [String] {
        if let alias = sshAlias, !alias.isEmpty {
            return identityArgs + [alias]
        }
        var args = identityArgs
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
        case id, name, folder, hostname, user, port, sshAlias, identityFile, savePassword
        case source, environment, isProtected, runOnConnect
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
        identityFile = try c.decodeIfPresent(String.self, forKey: .identityFile)
        savePassword = try c.decodeIfPresent(Bool.self, forKey: .savePassword) ?? false
        source = try c.decodeIfPresent(Source.self, forKey: .source) ?? .manual
        environment = try c.decodeIfPresent(HostEnvironment.self, forKey: .environment) ?? .none
        isProtected = try c.decodeIfPresent(Bool.self, forKey: .isProtected) ?? false
        runOnConnect = try c.decodeIfPresent(String.self, forKey: .runOnConnect)
    }
}

/// App-wide fallback credentials applied to sessions that don't set their own.
struct ConnectionDefaults: Codable, Equatable {
    var user: String?
    var identityFile: String?
}

/// One entry in the "jump back in" history: which host, connected when.
struct RecentConnection: Codable, Hashable {
    var entryID: UUID
    var date: Date
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
    /// `explicitFolders` are standalone (possibly empty) folders that should
    /// render even when no session lives in them.
    static func build(
        entries: [SessionEntry],
        explicitFolders: [String] = []
    ) -> (root: [SessionEntry], folders: [FolderNode]) {
        let root = entries.filter { $0.folder.isEmpty }.sorted(by: byName)

        // Every folder path, expanded so each ancestor exists as a node too.
        var paths = Set<String>()
        func addWithAncestors(_ path: String) {
            var prefix = ""
            for part in path.split(separator: "/") {
                prefix = prefix.isEmpty ? String(part) : prefix + "/" + part
                paths.insert(prefix)
            }
        }
        for entry in entries where !entry.folder.isEmpty { addWithAncestors(entry.folder) }
        for folder in explicitFolders { addWithAncestors(folder) }

        var directEntries: [String: [SessionEntry]] = [:]
        for entry in entries where !entry.folder.isEmpty {
            directEntries[entry.folder, default: []].append(entry)
        }

        return (root, childNodes(parent: "", paths: paths, directEntries: directEntries))
    }

    private static func childNodes(
        parent: String,
        paths: Set<String>,
        directEntries: [String: [SessionEntry]]
    ) -> [FolderNode] {
        let prefix = parent.isEmpty ? "" : parent + "/"
        let depth = parent.isEmpty ? 1 : parent.split(separator: "/").count + 1
        let children = paths.filter { $0.hasPrefix(prefix) && $0.split(separator: "/").count == depth }
        let sorted = children.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return sorted.map { path in
            FolderNode(
                path: path,
                name: String(path.split(separator: "/").last ?? Substring(path)),
                subfolders: childNodes(parent: path, paths: paths, directEntries: directEntries),
                entries: (directEntries[path] ?? []).sorted(by: byName)
            )
        }
    }

    private static func byName(_ a: SessionEntry, _ b: SessionEntry) -> Bool {
        a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
}
