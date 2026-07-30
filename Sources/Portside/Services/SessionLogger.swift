import Foundation

/// Writes a plain-text transcript of one session's output. Terminal output is
/// stripped of ANSI/control sequences (so logs stay greppable) and periodic
/// time markers are inserted after idle gaps, so you can tell when each burst
/// of activity happened. All file work happens on a private serial queue so
/// heavy output never blocks the UI.
final class SessionLogger {
    let fileURL: URL
    private let handle: FileHandle
    /// Bytes written so far. Only ever touched on `queue` -- reading it
    /// directly from the terminal's thread was both a data race and wrong:
    /// `append` merely *enqueues* a chunk, so the counter still reflected the
    /// state before it. Use `settledOffset()`.
    private var bytesWritten: Int = 0
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
        // Strong capture, deliberately -- see `close()`.
        queue.async { self.ingest(bytes) }
    }

    /// Offset once everything appended so far has actually been written.
    ///
    /// Synchronises with the writer queue, so call it only where a position is
    /// genuinely needed -- at a command boundary, never per chunk. Because
    /// `append` enqueues before this runs, the wait guarantees the chunk that
    /// carried the command has landed, which a direct read did not.
    func settledOffset() -> Int {
        queue.sync { bytesWritten }
    }

    /// Writes the footer and closes the file. Idempotent.
    ///
    /// The queued block captures `self` strongly on purpose. `close` is the
    /// last thing a session does and callers routinely release their reference
    /// straight afterwards -- `SessionManager` holds the only one, and a tab
    /// closing can deallocate it in the same turn. Under `[weak self]` the
    /// block then found nil and silently dropped both the footer and whatever
    /// `append` chunks were still queued behind it, so a transcript could end
    /// mid-line with no record that the session had ended. The retain is
    /// temporary: the queue is never suspended, so the block always runs and
    /// then releases. `append` captures strongly for the same reason.
    func close() {
        queue.async {
            guard !self.closed else { return }
            self.closed = true
            let footer = "\n──── session ended \(self.stamp.string(from: Date())) ────\n"
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
        if let data = string.data(using: .utf8) {
            try? handle.write(contentsOf: data)
            bytesWritten += data.count
        }
    }

    private func writeData(_ data: Data) {
        try? handle.write(contentsOf: data)
        bytesWritten += data.count
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
    /// Bytes consumed since the current sequence began. Reset on every return
    /// to `.normal`.
    private var sequenceLength = 0

    /// How long a single escape sequence may run before the stripper assumes
    /// the stream is malformed, gives up, and resumes emitting text.
    ///
    /// Without a ceiling one unterminated OSC swallows the rest of the
    /// session: the stripper stays in `.osc` forever and every subsequent byte
    /// is discarded, so the transcript just stops with nothing to indicate
    /// why. The bound is deliberately generous because Portside renders inline
    /// images, and an iTerm2 (OSC 1337) or Sixel (DCS) payload is legitimately
    /// enormous -- a screenshot runs to megabytes of base64. Anything under
    /// this passes through and is stripped as intended; the cost of the escape
    /// hatch is that a payload *larger* than this leaks its tail into the
    /// transcript as text. That is the better failure: visible noise in one
    /// log beats silently truncating everything that follows.
    static let maxSequenceLength = 4 << 20   // 4 MiB

    mutating func strip(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        for b in bytes {
            // CAN and SUB abort a sequence in flight from any state
            // (ECMA-48 8.3.5, 8.3.57). A terminal that honours them will have
            // stopped interpreting too, so a stripper that ignores them ends
            // up disagreeing with the screen about where the sequence ended --
            // exactly the mismatch that made SwiftTerm's Sixel handler
            // reachable from ordinary output. Mirror the exits, not just the
            // entries.
            if state != .normal, b == 0x18 || b == 0x1A {
                state = .normal
                sequenceLength = 0
                continue
            }

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
                // SOS / PM / APC are string sequences terminated by ST, same
                // as OSC. They used to fall into `default` below, which
                // swallowed only the introducer and then emitted the whole
                // body as if it were text -- a status or privacy message
                // landing in the transcript as garbage.
                case 0x58, 0x5E, 0x5F: state = .osc // X ^ _
                case 0x28, 0x29, 0x2A, 0x2B: state = .charset  // ( ) * + designate charset
                default: state = .normal            // 2-byte ESC seq: swallow this byte
                }
            case .csi:
                // Parameters/intermediates until a final byte 0x40–0x7E.
                if (0x40...0x7E).contains(b) { state = .normal }
            case .osc:
                // BEL, or ST in either spelling. 0x9C is the C1 form; treating
                // it as a terminator can in principle cut an OSC short when
                // the body carries UTF-8 whose continuation bytes include
                // 0x9C, but erring toward ending the sequence keeps output
                // flowing, while erring the other way loses the transcript.
                if b == 0x07 || b == 0x9C { state = .normal }
                else if b == 0x1B { state = .oscEsc }
            case .oscEsc:
                state = (b == 0x5C) ? .normal : .osc // ESC \ terminates (ST)
            case .dcs:
                if b == 0x9C { state = .normal }
                else if b == 0x1B { state = .dcsEsc }
            case .dcsEsc:
                state = (b == 0x5C) ? .normal : .dcs
            case .charset:
                state = .normal                     // one designating byte, then done
            }

            if state == .normal {
                sequenceLength = 0
            } else {
                sequenceLength += 1
                if sequenceLength > Self.maxSequenceLength {
                    state = .normal
                    sequenceLength = 0
                }
            }
        }
        return out
    }
}
