import Foundation

/// Imports MobaXterm exports:
/// - `.mxtsessions`: INI-style bookmark sections. `SubRep` gives the folder
///   path (backslash-separated); session lines are
///   `Name=#<icon>#<type>%host%port%user%...` where type 0 = SSH.
/// - `.mxtmacros`: `[Macros]` lines of pipe-delimited keystroke tuples
///   (`258:<code>:<locale>:<char>`), with `RETURN` and `SLEEPEQUAL<ms>` tokens.
enum MobaXtermImporter {
    struct Result {
        var entries: [SessionEntry] = []
        var macros: [Macro] = []
        var skippedNonSSH = 0
    }

    static func importFile(at url: URL) throws -> Result {
        let data = try Data(contentsOf: url)
        // MobaXterm writes Windows-1252; fall back through common encodings.
        guard let content = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1)
        else {
            throw CocoaError(.fileReadCorruptFile)
        }

        if url.pathExtension.lowercased() == "mxtmacros" {
            return parseMacros(content)
        }
        var result = parseSessions(content)
        // Some exports bundle macros alongside sessions.
        let macroResult = parseMacros(content)
        result.macros = macroResult.macros
        return result
    }

    // MARK: - Sessions

    static func parseSessions(_ content: String) -> Result {
        var result = Result()
        var currentFolder = ""
        var inBookmarks = false

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("[") {
                inBookmarks = line.lowercased().hasPrefix("[bookmarks")
                currentFolder = ""
                continue
            }
            guard inBookmarks, let eq = line.firstIndex(of: "=") else { continue }

            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)

            switch key {
            case "SubRep":
                currentFolder = value
                    .replacingOccurrences(of: "\\", with: "/")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            case "ImgNum":
                break
            default:
                if let entry = parseSessionLine(name: key, value: value, folder: currentFolder) {
                    result.entries.append(entry)
                } else if !value.isEmpty {
                    result.skippedNonSSH += 1
                }
            }
        }
        return result
    }

    private static func parseSessionLine(name: String, value: String, folder: String) -> SessionEntry? {
        guard let hashIndex = value.firstIndex(of: "#") else { return nil }
        let fields = String(value[hashIndex...]).components(separatedBy: "%")

        // fields[0] is "#<icon>#<type>", e.g. "#109#0" — type 0 is SSH.
        let header = fields[0].split(separator: "#").map(String.init)
        guard header.count >= 2, header[1] == "0", fields.count > 3 else { return nil }

        let host = fields[1].trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return nil }

        let port = Int(fields[2])
        var user: String? = fields[3].trimmingCharacters(in: .whitespaces)
        if user == "<default>" || user?.isEmpty == true { user = nil }

        return SessionEntry(
            name: name.replacingOccurrences(of: "__DIEZE__", with: "#"),
            folder: folder,
            hostname: host,
            user: user,
            port: port == 22 ? nil : port,
            source: .mobaxterm
        )
    }

    // MARK: - Macros

    static func parseMacros(_ content: String) -> Result {
        var result = Result()
        var inMacros = false

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inMacros = line.lowercased() == "[macros]"
                continue
            }
            guard inMacros, let eq = line.firstIndex(of: "=") else { continue }

            let name = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let sequence = String(line[line.index(after: eq)...])
            guard !name.isEmpty, !sequence.isEmpty else { continue }

            var text = ""
            var endedWithReturn = false
            for token in sequence.components(separatedBy: "|") {
                if token == "RETURN" {
                    text.append("\n")
                    endedWithReturn = true
                    continue
                }
                let parts = token.components(separatedBy: ":")
                guard parts.count >= 4 else { continue }
                let char = parts.dropFirst(3).joined(separator: ":")
                if char.hasPrefix("SLEEPEQUAL") { continue }
                text.append(char)
                endedWithReturn = false
            }
            if endedWithReturn, text.hasSuffix("\n") {
                text.removeLast()
            }
            guard !text.isEmpty else { continue }
            result.macros.append(Macro(name: name, text: text, sendReturn: endedWithReturn))
        }
        return result
    }
}
