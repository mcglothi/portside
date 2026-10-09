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
    /// Printed while no command was open. A finish with no start seen is a
    /// command that was already running when the capture began (typing was
    /// switched on mid-command); this is its output since then. Cleared at
    /// every prompt and command start, so it never holds a prompt and its
    /// typing as anyone's output.
    private var unclaimed: [UInt8] = []
    private var unclaimedDropped = false
    static let alreadyRunning = "(already running when typing was switched on)"
    private(set) var completed: [Command] = []
    /// Commands finished since the capture began. Only ever grows, unlike
    /// `completed`, which is capped — so "has a command finished since I
    /// asked?" stays answerable after the fifth one.
    private(set) var finishedTotal = 0
    /// The terminal's width, kept current by the view. A carriage return goes
    /// back to the start of the *row*, so a line that wrapped can only be
    /// replayed knowing where it wrapped. 0 means unknown: each line is then
    /// treated as one row, which is right for anything that never wrapped.
    var columns = 0

    /// The command still running, with what it has printed so far.
    var running: Command? {
        guard recording else { return nil }
        var copy = stripper
        return Command(command: pendingCommand, exitCode: nil,
                       output: Self.text(copy.strip(Self.tail(raw)), columns: columns),
                       truncated: dropped || raw.count > Self.maxBytesPerCommand, finished: false)
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
                if Self.trim(&raw) { dropped = true }
            } else {
                unclaimed.append(byte)
                if Self.trim(&unclaimed) { unclaimedDropped = true }
            }
            for marker in parser.consume([byte][...]) {
                switch marker {
                case .commandStart:
                    if recording { finish(exitCode: nil) }
                    begin()
                case .commandText(let text):
                    pendingCommand = text
                case .commandFinished(let code):
                    if recording { finish(exitCode: code) }
                    else { finishUnclaimed(exitCode: code) }
                case .promptStart:
                    unclaimed = []
                    unclaimedDropped = false
                }
            }
        }
    }

    /// Keeps a buffer's last `maxBytesPerCommand` bytes, trimming only once it
    /// has doubled. Trimming on every byte past the cap shifted 32 KB per
    /// byte, so a command printing megabytes stalled the terminal's receive
    /// path; this way each byte is moved at most once more. Readers take the
    /// `tail`. Returns whether anything was dropped.
    private static func trim(_ buffer: inout [UInt8]) -> Bool {
        guard buffer.count >= maxBytesPerCommand * 2 else { return false }
        buffer.removeFirst(buffer.count - maxBytesPerCommand)
        return true
    }

    private static func tail(_ buffer: [UInt8]) -> [UInt8] {
        buffer.count > maxBytesPerCommand ? Array(buffer.suffix(maxBytesPerCommand)) : buffer
    }

    /// A finish whose start came before the capture did. Only the first such
    /// one counts: after it the shell is back at a prompt, and from there on
    /// every command is seen starting.
    private mutating func finishUnclaimed(exitCode: Int?) {
        guard finishedTotal == 0, completed.isEmpty else { return }
        raw = unclaimed
        dropped = unclaimedDropped
        stripper = ANSIStripper(keepsLineEditing: true)
        pendingCommand = Self.alreadyRunning
        finish(exitCode: exitCode)
    }

    private mutating func begin() {
        unclaimed = []
        unclaimedDropped = false
        recording = true
        raw = []
        dropped = false
        stripper = ANSIStripper(keepsLineEditing: true)
    }

    private mutating func finish(exitCode: Int?) {
        let output = Self.text(stripper.strip(Self.tail(raw)), columns: columns)
        completed.append(Command(command: pendingCommand, exitCode: exitCode, output: output,
                                 truncated: dropped || raw.count > Self.maxBytesPerCommand, finished: true))
        finishedTotal += 1
        if completed.count > Self.kept { completed.removeFirst(completed.count - Self.kept) }
        recording = false
        raw = []
        pendingCommand = ""
        unclaimed = []
        unclaimedDropped = false
    }

    /// Stripped bytes as text: line editing replayed (see `render`), then
    /// control characters (already mostly gone) removed.
    static func text(_ bytes: [UInt8], columns: Int) -> String {
        render(String(decoding: bytes, as: UTF8.self), columns: columns)
            .unicodeScalars.filter { $0 == "\n" || $0 == "\t" || !CharacterSet.controlCharacters.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Replays CR, BS and erase-in-line (the stripper's `Erase` markers) the
    /// way the terminal did, so the text is what was on screen rather than
    /// every keystroke of how it got there.
    ///
    /// Treating CR as a line break used to turn a progress bar into one line
    /// per frame. Dropping it doubled a character at every wrap of a long
    /// command line: once a line has wrapped, readline returns to the start
    /// of the new row and rewrites the character it just printed there
    /// (`…MN\rNOPQ…`), which reads as `MNN` with the CR gone.
    ///
    /// The cursor is a screen row and a column within it, plus whether a
    /// wrap is pending: a character written in a row's last column leaves the
    /// cursor *on* that column until the next character, which is when the
    /// terminal wraps. Kept as a flag because the column alone can't tell
    /// "end of a full row" from "start of the next", and guessing sent a
    /// second CR on a wrapped row back to the row above. Cursor up, down,
    /// right, left and to-column (the stripper's move markers) move it the
    /// way a terminal would, so a tool that redraws several lines — `docker
    /// pull`, BuildKit, cargo — comes back as its final screen. Up stops at
    /// the command's first row: what was above isn't its output. Wide
    /// characters count as one column; the cost is an occasional misplaced
    /// overwrite in CJK output.
    static func render(_ text: String, columns: Int) -> String {
        let width = columns > 0 ? columns : Int.max
        // Screen rows, and for each whether it carries on the row above it
        // (a soft wrap) — so a long line still comes back as one line. Rows,
        // not logical lines, because cursor movement is in screen rows: a
        // tool redrawing three lines moves up three rows.
        var rows: [[Character]] = [[]]
        var continues = [false]
        var r = 0, col = 0
        var wrapPending = false
        func ensure(_ row: Int) { while rows.count <= row { rows.append([]); continues.append(false) } }
        func blank(_ range: Range<Int>) {
            let range = range.clamped(to: 0..<rows[r].count)
            guard !range.isEmpty else { return }
            if range.upperBound == rows[r].count { rows[r].removeSubrange(range) }
            else { rows[r].replaceSubrange(range, with: repeatElement(" ", count: range.count)) }
        }
        let move = Character(Unicode.Scalar(ANSIStripper.moveMarker))
        var chars = text.makeIterator()
        while let ch = chars.next() {
            switch ch {
            case "\n", "\r\n":
                r += 1
                ensure(r)
                col = 0
                wrapPending = false
            case "\r":
                col = 0
                wrapPending = false
            case "\u{08}":
                wrapPending = false
                if col > 0 { col -= 1 }
            case ANSIStripper.Erase.toEnd.character:
                blank(col..<rows[r].count)
            case ANSIStripper.Erase.toStart.character:
                blank(0..<(col + 1))
            case ANSIStripper.Erase.line.character:
                blank(0..<rows[r].count)
            case move:
                // `US <final> <count> US`, from the stripper.
                guard let final = chars.next() else { break }
                var digits = ""
                while let d = chars.next(), d != move { digits.append(d) }
                let n = max(Int(digits) ?? 1, 1)
                wrapPending = false
                switch final {
                case "A": r = max(0, r - n)           // never above the command's own output
                case "B": r += n; ensure(r)
                case "C": col = width == .max ? col + n : min(col + n, width - 1)
                case "D": col = max(0, col - n)
                case "G": col = width == .max ? n - 1 : min(n - 1, width - 1)
                default: break
                }
            default:
                if wrapPending {
                    r += 1
                    ensure(r)
                    continues[r] = true
                    col = 0
                    wrapPending = false
                }
                if col < rows[r].count { rows[r][col] = ch }
                else {
                    rows[r].append(contentsOf: repeatElement(" ", count: col - rows[r].count))
                    rows[r].append(ch)
                }
                if width != .max, col == width - 1 { wrapPending = true } else { col += 1 }
            }
        }
        var lines: [String] = []
        for (i, row) in rows.enumerated() {
            if i > 0, continues[i], !lines.isEmpty { lines[lines.count - 1] += String(row) }
            else { lines.append(String(row)) }
        }
        return lines.joined(separator: "\n")
    }
}
