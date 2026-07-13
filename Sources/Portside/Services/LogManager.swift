import Foundation

/// Owns the on-disk log tree: per-host subfolders, the logger factory, the
/// compression sweep, and search. Logs live at
/// `<base>/<host>/<host>_<timestamp>.log`, keyed by hostname (not user@host)
/// so one host's sessions gather in one folder regardless of which account.
enum LogManager {

    // MARK: - Layout

    /// Folder name for a host: prefer the real hostname, then an ssh alias,
    /// then the display name; serial sessions key on the device and telnet
    /// sessions on host:port. Sanitized for the filesystem.
    static func hostKey(for entry: SessionEntry) -> String {
        let raw: String
        if entry.kind == .serial, let device = entry.serial?.deviceName, !device.isEmpty {
            raw = device
        } else if entry.kind == .telnet, let target = entry.telnet, !target.host.isEmpty {
            raw = "\(target.host):\(target.port)"
        } else {
            raw = !entry.hostname.isEmpty ? entry.hostname
                : (entry.sshAlias?.isEmpty == false ? entry.sshAlias! : entry.name)
        }
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        let cleaned = String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return cleaned.isEmpty ? "unknown" : cleaned
    }

    static func hostDirectory(for entry: SessionEntry, settings: LoggingSettings) -> URL {
        settings.resolvedDirectory.appendingPathComponent(hostKey(for: entry))
    }

    // MARK: - Logger factory

    private static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    /// Creates a logger for a session, or nil when logging is off.
    static func makeLogger(for entry: SessionEntry, settings: LoggingSettings) -> SessionLogger? {
        makeLogger(hostKey: hostKey(for: entry), title: entry.name,
                   subtitle: entry.subtitle, settings: settings)
    }

    static func makeLogger(hostKey key: String, title: String, subtitle: String,
                           settings: LoggingSettings) -> SessionLogger? {
        guard settings.enabled else { return nil }
        let dir = settings.resolvedDirectory.appendingPathComponent(key)
        var url = dir.appendingPathComponent("\(key)_\(fileStamp.string(from: Date())).log")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(key)_\(fileStamp.string(from: Date()))-\(n).log")
            n += 1
        }
        return SessionLogger(fileURL: url, title: title, subtitle: subtitle)
    }

    // MARK: - Maintenance (compression)

    /// gzips logs older than the configured age. Safe to call on launch.
    static func runMaintenance(settings: LoggingSettings) {
        guard settings.compressAfterDays > 0 else { return }
        let base = settings.resolvedDirectory
        let cutoff = Date().addingTimeInterval(-Double(settings.compressAfterDays) * 86_400)
        DispatchQueue.global(qos: .background).async {
            guard let enumerator = FileManager.default.enumerator(
                at: base, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
            for case let url as URL in enumerator where url.pathExtension == "log" {
                let mdate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                guard let mdate, mdate < cutoff else { continue }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
                p.arguments = ["-q", url.path]        // creates url.gz, removes original
                try? p.run()
                p.waitUntilExit()
            }
        }
    }

    // MARK: - Search

    /// Searches every `.log` (and `.log.gz`) under the base dir for `query`
    /// (case-insensitive substring), returning matches with a little context.
    static func search(_ query: String, settings: LoggingSettings, limit: Int = 500) -> [LogMatch] {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return [] }
        let base = settings.resolvedDirectory
        guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
        else { return [] }

        var matches: [LogMatch] = []
        for case let url as URL in enumerator {
            let ext = url.pathExtension
            let isGz = ext == "gz" && url.deletingPathExtension().pathExtension == "log"
            guard ext == "log" || isGz else { continue }
            guard let text = contents(of: url, gzipped: isGz) else { continue }

            let host = url.deletingLastPathComponent().lastPathComponent
            let lines = text.components(separatedBy: "\n")
            var currentStamp = fileDateString(url)
            for (i, line) in lines.enumerated() {
                if let s = timeMarker(in: line) { currentStamp = s }
                if line.lowercased().contains(needle) {
                    let lo = max(0, i - 2), hi = min(lines.count - 1, i + 2)
                    matches.append(LogMatch(
                        host: host, fileURL: url, lineNumber: i + 1,
                        timestamp: currentStamp, line: line.trimmingCharacters(in: .whitespaces),
                        context: Array(lines[lo...hi])))
                    if matches.count >= limit { return matches }
                }
            }
        }
        return matches
    }

    private static func contents(of url: URL, gzipped: Bool) -> String? {
        if !gzipped { return try? String(contentsOf: url, encoding: .utf8) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        p.arguments = ["-dc", url.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// Extracts the time from a "──[ 2026-07-09 10:05:30 ... ]──" marker line.
    private static func timeMarker(in line: String) -> String? {
        guard line.contains("──[") , let open = line.range(of: "["), let close = line.range(of: "]") else {
            return nil
        }
        return String(line[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespaces)
    }

    private static func fileDateString(_ url: URL) -> String {
        let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }
}
