import Foundation

/// What the last few commands in a session printed, for an agent's "what did
/// that do?"
///
/// The cheap, precise alternative to reading the screen or the log. Shell
/// integration already marks each command's start (OSC 133 C) and finish
/// (OSC 133 D, with the exit status); the bytes in between *are* that command's
/// output. Keeping them — stripped of escape sequences, capped — gives an agent
/// `df -h → exit 0 → these 12 lines` instead of fifty lines of screen it has
/// to pick the answer out of, or a transcript it has to pay to read whole.
///
/// Only allocated while agents may read sessions, so nobody else pays the
/// per-byte scan.
struct CommandOutputCapture {
    struct Command: Equatable {
        var command: String
        var exitCode: Int?
        var output: String
        /// Output beyond the cap was dropped from the *start*; the end, where
        /// errors and summaries land, is kept.
        var truncated: Bool
        var finished: Bool
    }

    static let maxBytesPerCommand = 32 * 1024
    static let kept = 5

    private var parser = OSC133Parser()
    private var stripper = ANSIStripper(keepsLineEditing: true)
    private var recording = false
    private var raw: [UInt8] = []
    private var dropped = false
    private var pendingCommand = ""
    private(set) var completed: [Command] = []
    /// Commands finished since the capture began. Only ever grows, unlike
    /// `completed`, which is capped — so "has a command finished since I
    /// asked?" stays answerable after the fifth one.
    private(set) var finishedTotal = 0
    /// Whether any OSC 133 marker has arrived. Without one nothing will ever
    /// finish, so an agent's wait can answer at once instead of running out.
    private(set) var sawShellIntegration = false
    /// The terminal's width, kept current by the view. A carriage return goes
    /// back to the start of the *row*, so a line that wrapped can only be
    /// replayed knowing where it wrapped. 0 means unknown: each line is then
    /// treated as one row, which is right for anything that never wrapped.
    var columns = 0

    /// The command still running, with what it has printed so far.
    var running: Command? {
        guard recording else { return nil }
        var copy = stripper
        return Command(command: pendingCommand, exitCode: nil, output: Self.text(copy.strip(raw), columns: columns),
                       truncated: dropped, finished: false)
    }

    /// Most recent first: the running command, if any, then completed ones.
    var recent: [Command] { (running.map { [$0] } ?? []) + completed.reversed() }

    /// The first command to finish after `finishedTotal` read `baseline` —
    /// the one an agent started then — while it's still kept. Not the head of
    /// `recent`: by the time a wait notices a finish, the next command can
    /// already be running, and that one has no exit code yet.
    func firstFinished(after baseline: Int) -> Command? {
        let since = finishedTotal - baseline
        guard since > 0, since <= completed.count else { return nil }
        return completed[completed.count - since]
    }

    mutating func consume(_ bytes: ArraySlice<UInt8>) {
        for byte in bytes {
            if recording {
                raw.append(byte)
                if raw.count > Self.maxBytesPerCommand {
                    raw.removeFirst(raw.count - Self.maxBytesPerCommand)
                    dropped = true
                }
            }
            for marker in parser.consume([byte][...]) {
                sawShellIntegration = true
                switch marker {
                case .commandStart:
                    if recording { finish(exitCode: nil) }
                    begin()
                case .commandText(let text):
                    pendingCommand = text
                case .commandFinished(let code):
                    if recording { finish(exitCode: code) }
                case .promptStart:
                    break
                }
            }
        }
    }

    private mutating func begin() {
        recording = true
        raw = []
        dropped = false
        stripper = ANSIStripper(keepsLineEditing: true)
    }

    private mutating func finish(exitCode: Int?) {
        let output = Self.text(stripper.strip(raw), columns: columns)
        completed.append(Command(command: pendingCommand, exitCode: exitCode, output: output,
                                 truncated: dropped, finished: true))
        finishedTotal += 1
        if completed.count > Self.kept { completed.removeFirst(completed.count - Self.kept) }
        recording = false
        raw = []
        pendingCommand = ""
    }

    /// Stripped bytes as text: line editing replayed (see `render`), then
    /// control characters (already mostly gone) removed.
    static func text(_ bytes: [UInt8], columns: Int) -> String {
        render(String(decoding: bytes, as: UTF8.self), columns: columns)
            .unicodeScalars.filter { $0 == "\n" || $0 == "\t" || !CharacterSet.controlCharacters.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Replays CR, BS and erase-in-line (VT, from the stripper) the way the
    /// terminal did, so the text is what was on screen rather than every
    /// keystroke of how it got there.
    ///
    /// Treating CR as a line break used to turn a progress bar into one line
    /// per frame. Dropping it doubled a character at every wrap of a long
    /// command line: once a line has wrapped, readline returns to the start
    /// of the new row and rewrites the character it just printed there
    /// (`…MN\rNOPQ…`), which reads as `MNN` with the CR gone.
    ///
    /// The cursor is a position within the current logical line; with the
    /// width known, a CR goes back to the start of its row. A position that
    /// is an exact multiple of the width is still on the row it filled — the
    /// terminal defers the wrap until the next character — so CR there goes
    /// to the start of that row, not the next. Wide characters count as one
    /// column; the cost is an occasional misplaced overwrite in CJK output.
    static func render(_ text: String, columns: Int) -> String {
        let width = columns > 0 ? columns : Int.max
        func rowStart(_ pos: Int) -> Int { pos == 0 ? 0 : (pos - 1) / width * width }
        var lines: [String] = []
        var row: [Character] = []
        var pos = 0
        for ch in text {
            switch ch {
            case "\n", "\r\n":
                lines.append(String(row))
                row = []
                pos = 0
            case "\r":
                pos = rowStart(pos)
            case "\u{08}":
                if pos > rowStart(pos) { pos -= 1 }
            case "\u{0B}":
                guard pos < row.count else { break }
                let start = rowStart(pos)
                let end = width == .max ? row.count : min(row.count, start + width)
                if end == row.count { row.removeSubrange(pos..<end) }
                else { row.replaceSubrange(pos..<end, with: repeatElement(" ", count: end - pos)) }
            default:
                if pos < row.count { row[pos] = ch }
                else {
                    row.append(contentsOf: repeatElement(" ", count: pos - row.count))
                    row.append(ch)
                }
                pos += 1
            }
        }
        lines.append(String(row))
        return lines.joined(separator: "\n")
    }
}
