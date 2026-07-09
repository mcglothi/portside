import Darwin
import Foundation

/// Parses `~/.ssh/config` (following `Include` directives) into session
/// entries. Pattern entries (`*`, `?`, negations) are skipped — they
/// configure matching, they aren't connectable hosts.
enum SSHConfigImporter {
    static var defaultConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
    }

    static func importEntries(from url: URL = defaultConfigURL) -> [SessionEntry] {
        var visited = Set<String>()
        var entries: [SessionEntry] = []
        parse(url: url, visited: &visited, entries: &entries)
        return entries.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func parse(url: URL, visited: inout Set<String>, entries: inout [SessionEntry]) {
        guard !visited.contains(url.path),
              let content = try? String(contentsOf: url, encoding: .utf8)
        else { return }
        visited.insert(url.path)

        var current: [SessionEntry] = []
        func flush() {
            entries.append(contentsOf: current)
            current = []
        }

        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let tokens = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard tokens.count == 2 else { continue }
            let keyword = tokens[0].lowercased()
            let value = tokens[1].trimmingCharacters(in: .whitespaces)

            switch keyword {
            case "host":
                flush()
                current = value.split(whereSeparator: { $0.isWhitespace })
                    .map(String.init)
                    .filter { !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!") }
                    .map { alias in
                        SessionEntry(name: alias, hostname: alias, sshAlias: alias, source: .sshConfig)
                    }
            case "hostname":
                for i in current.indices { current[i].hostname = value }
            case "user":
                for i in current.indices { current[i].user = value }
            case "port":
                for i in current.indices { current[i].port = Int(value) }
            case "include":
                for pattern in value.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
                    let expanded = (pattern as NSString).expandingTildeInPath
                    let full = expanded.hasPrefix("/")
                        ? expanded
                        : url.deletingLastPathComponent().appendingPathComponent(expanded).path
                    for match in glob(full) {
                        parse(url: URL(fileURLWithPath: match), visited: &visited, entries: &entries)
                    }
                }
            default:
                break
            }
        }
        flush()
    }

    private static func glob(_ pattern: String) -> [String] {
        var g = glob_t()
        defer { globfree(&g) }
        guard Darwin.glob(pattern, 0, nil, &g) == 0 else { return [] }
        return (0..<Int(g.gl_pathc)).compactMap { i in
            g.gl_pathv[i].map { String(cString: $0) }
        }
    }
}
