import Foundation

/// Writes a plain-text transcript of one session's output. Terminal output is
/// stripped of ANSI/control sequences (so logs stay greppable) and periodic
/// time markers are inserted after idle gaps, so you can tell when each burst
/// of activity happened. All file work happens on a private serial queue so
/// heavy output never blocks the UI.
final class SessionLogger {
    let fileURL: URL
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "net.timmcg.portside.sessionlog", qos: .utility)
    private var stripper = ANSIStripper()
    private var lastWrite = Date()
    private var closed = false

    /// Insert a fresh timestamp when output resumes after this many idle seconds.
    private let idleGapSeconds: TimeInterval = 15

    // Per-instance (DateFormatter isn't thread-safe); only touched on `queue`
    // after init, so concurrent loggers never share one.
    private let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f
    }()

    init?(fileURL: URL, title: String, subtitle: String) {
        self.fileURL = fileURL
        let fm = FileManager.default
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.createFile(atPath: fileURL.path, contents: nil) { return nil }
        guard let h = try? FileHandle(forWritingTo: fileURL) else { return nil }
        handle = h

        let header = """
        ════════════════════════════════════════════════════════
         Portside session log
         Host:    \(title)\(subtitle.isEmpty ? "" : " (\(subtitle))")
         Started: \(stamp.string(from: Date()))
        ════════════════════════════════════════════════════════

        """
        write(header)
    }

    func append(_ slice: ArraySlice<UInt8>) {
        let bytes = [UInt8](slice)
        queue.async { [weak self] in self?.ingest(bytes) }
    }

    func close() {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.closed = true
            let footer = "\n──── session ended \(stamp.string(from: Date())) ────\n"
            if let data = footer.data(using: .utf8) { try? self.handle.write(contentsOf: data) }
            try? self.handle.close()
        }
    }

    // MARK: - private (serial queue)

    private func ingest(_ bytes: [UInt8]) {
        guard !closed else { return }
        let cleaned = stripper.strip(bytes)
        guard !cleaned.isEmpty else { return }

        let now = Date()
        if now.timeIntervalSince(lastWrite) > idleGapSeconds {
            writeData("\n──[ \(stamp.string(from: now)) ]──\n".data(using: .utf8) ?? Data())
        }
        lastWrite = now
        writeData(Data(cleaned))
    }

    private func write(_ string: String) {
        if let data = string.data(using: .utf8) { try? handle.write(contentsOf: data) }
    }

    private func writeData(_ data: Data) {
        try? handle.write(contentsOf: data)
    }
}

/// Byte-level stripper for ANSI escape / control sequences. Operates on the
/// raw stream (state persists across chunks, since a sequence can straddle a
/// read) and leaves UTF-8 text and newlines/tabs intact.
struct ANSIStripper {
    private enum State {
        case normal, escape, csi, osc, oscEsc, charset, dcs, dcsEsc
    }
    private var state: State = .normal

    mutating func strip(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        for b in bytes {
            switch state {
            case .normal:
                switch b {
                case 0x1B: state = .escape          // ESC
                case 0x0A, 0x09: out.append(b)      // keep LF, TAB
                case 0x0D, 0x08: break              // drop CR, BS (overwrite noise)
                case 0..<0x20, 0x7F: break          // drop other control chars
                default: out.append(b)              // printable / UTF-8
                }
            case .escape:
                switch b {
                case 0x5B: state = .csi             // '['
                case 0x5D: state = .osc             // ']'
                case 0x50: state = .dcs             // 'P' (DCS)
                case 0x28, 0x29, 0x2A, 0x2B: state = .charset  // ( ) * + designate charset
                default: state = .normal            // 2-byte ESC seq: swallow this byte
                }
            case .csi:
                // Parameters/intermediates until a final byte 0x40–0x7E.
                if (0x40...0x7E).contains(b) { state = .normal }
            case .osc:
                if b == 0x07 { state = .normal }    // BEL terminates
                else if b == 0x1B { state = .oscEsc }
            case .oscEsc:
                state = (b == 0x5C) ? .normal : .osc // ESC \ terminates (ST)
            case .dcs:
                if b == 0x1B { state = .dcsEsc }
            case .dcsEsc:
                state = (b == 0x5C) ? .normal : .dcs
            case .charset:
                state = .normal                     // one designating byte, then done
            }
        }
        return out
    }
}
