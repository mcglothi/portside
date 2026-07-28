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
    /// `excludeProtected` comes from the recording privacy setting. Logging
    /// previously ignored it entirely, so a user who opted a protected host out
    /// of history still had that host's full terminal transcript -- including
    /// anything echoed to the screen -- written to disk. The setting read as a
    /// privacy guarantee while covering only part of the surface.
    static func makeLogger(
        for entry: SessionEntry, settings: LoggingSettings, excludeProtected: Bool = false
    ) -> SessionLogger? {
        guard !(excludeProtected && entry.isProtected) else { return nil }
        return makeLogger(hostKey: hostKey(for: entry), title: entry.name,
                          subtitle: entry.subtitle, settings: settings)
    }

    /// A window of the transcript around a recorded command, so history can
    /// show what actually happened rather than just that something ran.
    ///
    /// Reads by seeking rather than loading the file: a long session's
    /// transcript can be very large, and this is called while scrolling a list.
    /// Returns nil if the transcript has since been compressed, moved, or
    /// deleted — recorded commands outlive the files they point at.
    static func excerpt(path: String, around offset: Int, span: Int = 1_600) -> String? {
        guard FileManager.default.fileExists(atPath: path),
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }

        let start = max(0, offset - span / 2)
        guard (try? handle.seek(toOffset: UInt64(start))) != nil,
              let data = try? handle.read(upToCount: span), !data.isEmpty else { return nil }

        // A window into UTF-8 can start or end mid-character; drop the ragged
        // edges rather than failing to decode the whole excerpt.
        var bytes = [UInt8](data)
        while !bytes.isEmpty && (bytes[0] & 0xC0) == 0x80 { bytes.removeFirst() }
        while !bytes.isEmpty && String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
        return String(bytes: bytes, encoding: .utf8)
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

    // MARK: - Ownership

    /// Matches exactly the filenames `makeLogger` generates —
    /// `<hostKey>_yyyy-MM-dd_HH-mm-ss[-n].log`, optionally already
    /// gzip-compressed. The transcript folder is user-chosen in Settings and
    /// can be an *existing* directory (Documents, an existing log tree, a
    /// whole home folder); maintenance and search must never mutate or read
    /// a file just because it happens to end in `.log` — only ones Portside
    /// itself is confident it wrote.
    static func isOwnedLogFilename(_ name: String) -> Bool {
        let pattern = #"^.+_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}(-\d+)?\.log(\.gz)?$"#
        return name.range(of: pattern, options: .regularExpression) != nil
    }

    /// Every log Portside owns under `base` — exactly the two-level shape
    /// `hostDirectory(for:settings:)` creates, `<base>/<hostKey>/<file>`, and
    /// nothing deeper. This walks two explicit directory listings rather
    /// than a recursive enumerator, so a subfolder the user happens to keep
    /// inside their chosen base (another app's logs, a git checkout) is
    /// never descended into at all, let alone touched.
    private static func ownedLogFiles(under base: URL) -> [URL] {
        let fm = FileManager.default
        let hostDirs = ((try? fm.contentsOfDirectory(
            at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }

        return hostDirs.flatMap { dir -> [URL] in
            let files = (try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )) ?? []
            return files.filter { isOwnedLogFilename($0.lastPathComponent) }
        }
    }

    // MARK: - Maintenance (compression)

    /// gzips logs older than the configured age. Safe to call on launch.
    static func runMaintenance(settings: LoggingSettings) {
        guard settings.compressAfterDays > 0 else { return }
        let base = settings.resolvedDirectory
        let cutoff = Date().addingTimeInterval(-Double(settings.compressAfterDays) * 86_400)
        DispatchQueue.global(qos: .background).async {
            for url in ownedLogFiles(under: base) where url.pathExtension == "log" {
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

    /// Searches every log Portside owns (`.log` and `.log.gz`) for `query`
    /// (case-insensitive substring), returning matches with a little context.
    static func search(_ query: String, settings: LoggingSettings, limit: Int = 500) -> [LogMatch] {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return [] }

        var matches: [LogMatch] = []
        for url in ownedLogFiles(under: settings.resolvedDirectory) {
            let isGz = url.pathExtension == "gz"
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

    /// Per-file cap on what search reads into memory — plain or decompressed.
    /// A real Portside transcript rarely approaches this; it exists so a
    /// corrupted or adversarial `.log.gz` (a decompression bomb: kilobytes on
    /// disk, gigabytes decompressed) can't be used to exhaust memory just by
    /// sitting in the transcript folder and getting searched.
    private static let maxSearchBytes = 100 * 1024 * 1024

    private static func contents(of url: URL, gzipped: Bool) -> String? {
        let data: Data
        if !gzipped {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            data = handle.readData(ofLength: maxSearchBytes)
        } else {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
            p.arguments = ["-dc", url.path]
            let pipe = Pipe()
            p.standardOutput = pipe
            do { try p.run() } catch { return nil }
            var collected = Data()
            let handle = pipe.fileHandleForReading
            while collected.count < maxSearchBytes {
                let chunk = handle.readData(ofLength: 1_048_576)
                if chunk.isEmpty { break }
                collected.append(chunk)
            }
            // Stop feeding gzip more input to decompress once the cap is hit —
            // otherwise a bomb keeps running to completion in the background
            // even though its output is already being discarded.
            if collected.count >= maxSearchBytes { p.terminate() }
            handle.closeFile()
            p.waitUntilExit()
            data = collected
        }
        // A capped read can stop mid UTF-8 character; drop the ragged tail
        // rather than failing to decode the whole (mostly valid) capture.
        var bytes = [UInt8](data)
        while !bytes.isEmpty, String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
        return String(bytes: bytes, encoding: .utf8)
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
