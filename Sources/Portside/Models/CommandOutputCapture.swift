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
    private var stripper = ANSIStripper()
    private var recording = false
    private var raw: [UInt8] = []
    private var dropped = false
    private var pendingCommand = ""
    private(set) var completed: [Command] = []

    /// The command still running, with what it has printed so far.
    var running: Command? {
        guard recording else { return nil }
        var copy = stripper
        return Command(command: pendingCommand, exitCode: nil, output: Self.text(copy.strip(raw)),
                       truncated: dropped, finished: false)
    }

    /// Most recent first: the running command, if any, then completed ones.
    var recent: [Command] { (running.map { [$0] } ?? []) + completed.reversed() }

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
        stripper = ANSIStripper()
    }

    private mutating func finish(exitCode: Int?) {
        let output = Self.text(stripper.strip(raw))
        completed.append(Command(command: pendingCommand, exitCode: exitCode, output: output,
                                 truncated: dropped, finished: true))
        if completed.count > Self.kept { completed.removeFirst(completed.count - Self.kept) }
        recording = false
        raw = []
        pendingCommand = ""
    }

    /// Stripped bytes as text: carriage returns resolved to line ends, and
    /// control characters (already mostly gone) removed.
    private static func text(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .unicodeScalars.filter { $0 == "\n" || $0 == "\t" || !CharacterSet.controlCharacters.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
