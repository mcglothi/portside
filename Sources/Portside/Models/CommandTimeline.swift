import Foundation

/// One command run in a session: what it was, when it started and finished, and
/// how it exited.
struct CommandEvent: Identifiable, Codable, Hashable {
    var id = UUID()
    var entryID: UUID?
    /// Empty when the shell reported a command boundary but no command text
    /// (bash's DEBUG trap can't always supply it).
    var command: String
    var startedAt: Date
    var finishedAt: Date?
    var exitCode: Int?
    /// Where this command appears in the session transcript, when logging was
    /// on for the session. Lets history act as a table of contents for the log
    /// rather than a second, disconnected record.
    var logPath: String?
    var logOffset: Int?

    var duration: TimeInterval? {
        finishedAt.map { $0.timeIntervalSince(startedAt) }
    }

    var succeeded: Bool? {
        exitCode.map { $0 == 0 }
    }
}

/// Scans the raw terminal byte stream for OSC 133 shell-integration markers.
///
/// SwiftTerm doesn't implement OSC 133 (only OSC 8), which this project
/// previously recorded as "blocked upstream" — but nothing requires SwiftTerm
/// to parse it. `LoggingTerminalView` already taps raw bytes before rendering,
/// which is where session logging happens, so the markers can be read there and
/// left for SwiftTerm to ignore.
///
/// Markers, emitted by the shell-integration snippet:
///
///   OSC 133 ; A            prompt about to be drawn
///   OSC 133 ; C            command starting
///   OSC 133 ; E ; <b64>    command text (base64, so ; and control bytes survive)
///   OSC 133 ; D ; <code>   command finished with exit status
///
/// Terminated by BEL (0x07) or ST (ESC \). Stateful because a sequence can be
/// split across reads — the same hazard that made the log's ANSI stripper
/// byte-level rather than line-based.
struct OSC133Parser {

    enum Marker: Equatable {
        case promptStart
        case commandStart
        case commandText(String)
        case commandFinished(exitCode: Int?)
    }

    private enum State {
        case idle
        /// Seen ESC, waiting to see if it begins an OSC.
        case escape
        /// Inside an OSC payload.
        case collecting
        /// Inside an OSC payload, having just seen ESC (possible ST).
        case collectingEscape
    }

    private var state: State = .idle
    private var payload: [UInt8] = []

    /// Guards against a malformed or hostile stream growing the buffer without
    /// bound when a terminator never arrives.
    private static let maxPayload = 8 * 1024

    /// Feeds bytes, returning any complete markers found.
    mutating func consume(_ bytes: ArraySlice<UInt8>) -> [Marker] {
        var markers: [Marker] = []
        for byte in bytes {
            switch state {
            case .idle:
                if byte == 0x1B { state = .escape }

            case .escape:
                if byte == 0x5D {           // ']'
                    state = .collecting
                    payload.removeAll(keepingCapacity: true)
                } else if byte == 0x1B {
                    // Another ESC; stay armed rather than dropping it.
                    state = .escape
                } else {
                    state = .idle
                }

            case .collecting:
                if byte == 0x07 {           // BEL terminator
                    if let marker = Self.marker(from: payload) { markers.append(marker) }
                    reset()
                } else if byte == 0x1B {
                    state = .collectingEscape
                } else {
                    payload.append(byte)
                    if payload.count > Self.maxPayload { reset() }
                }

            case .collectingEscape:
                if byte == 0x5C {           // ST terminator (ESC \)
                    if let marker = Self.marker(from: payload) { markers.append(marker) }
                    reset()
                } else {
                    // Not a terminator after all; the ESC was payload.
                    payload.append(0x1B)
                    payload.append(byte)
                    state = .collecting
                    if payload.count > Self.maxPayload { reset() }
                }
            }
        }
        return markers
    }

    private mutating func reset() {
        state = .idle
        payload.removeAll(keepingCapacity: true)
    }

    /// Interprets an OSC payload, ignoring anything that isn't a 133 marker —
    /// OSC 7 (working directory) and OSC 8 (hyperlinks) share this stream.
    static func marker(from payload: [UInt8]) -> Marker? {
        guard let text = String(bytes: payload, encoding: .utf8) else { return nil }
        let parts = text.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] == "133" else { return nil }

        switch parts[1] {
        case "A":
            return .promptStart
        case "C":
            return .commandStart
        case "E":
            guard parts.count >= 3,
                  let data = Data(base64Encoded: String(parts[2])),
                  let command = String(data: data, encoding: .utf8) else { return nil }
            return .commandText(command.trimmingCharacters(in: .whitespacesAndNewlines))
        case "D":
            // A bare D (no status) is legal; report it as finished-unknown
            // rather than dropping the boundary.
            guard parts.count >= 3 else { return .commandFinished(exitCode: nil) }
            return .commandFinished(exitCode: Int(parts[2]))
        default:
            return nil
        }
    }
}

/// Assembles markers into completed `CommandEvent`s.
///
/// Deliberately tolerant: shells emit these imperfectly. A `D` with no matching
/// `C` (the first prompt after login reports the *previous* exit status) is
/// discarded rather than inventing a command, and a second `C` without a `D`
/// closes the previous command instead of losing it.
struct CommandTimeline {
    private var parser = OSC133Parser()
    private var pending: CommandEvent?
    let entryID: UUID?

    init(entryID: UUID? = nil) {
        self.entryID = entryID
    }

    /// Feeds bytes, returning commands that completed in this chunk.
    mutating func consume(_ bytes: ArraySlice<UInt8>, now: Date = Date()) -> [CommandEvent] {
        var completed: [CommandEvent] = []
        for marker in parser.consume(bytes) {
            switch marker {
            case .promptStart:
                break

            case .commandStart:
                // An unterminated previous command closes here rather than
                // being silently dropped.
                if let open = pending {
                    completed.append(open)
                }
                pending = CommandEvent(entryID: entryID, command: "", startedAt: now)

            case .commandText(let command):
                if pending != nil {
                    pending?.command = command
                } else {
                    // Text without a start still describes a real command.
                    pending = CommandEvent(entryID: entryID, command: command, startedAt: now)
                }

            case .commandFinished(let code):
                guard var open = pending else { continue }
                open.finishedAt = now
                open.exitCode = code
                completed.append(open)
                pending = nil
            }
        }
        return completed
    }

    /// The command currently running, if any.
    var runningCommand: CommandEvent? { pending }
}
