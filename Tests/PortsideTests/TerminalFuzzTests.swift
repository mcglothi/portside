import XCTest
import SwiftTerm
@testable import Portside

/// Terminal compatibility suite — seeded fuzzing of the escape-sequence parser.
///
/// The hand-written stream tests check sequences someone thought of. These
/// build streams from a grammar of what programs actually send — cursor
/// motion with extreme parameters, SGR in every form, OSC, DCS, mode
/// switches, charset designations, UTF-8 that wraps and combines — plus the
/// same things cut off at a random byte, and check three properties of every
/// one:
///
/// 1. **Read boundaries don't matter.** A pty returns whatever `read()` had,
///    so the same bytes in random-sized chunks must leave the same screen and
///    cursor as the whole stream at once.
/// 2. **Nothing crashes or hangs**, however the sequences are mangled.
/// 3. **Nothing swallows the session.** After any stream, CAN (which aborts
///    a sequence in progress) and a line of text: the text is on screen.
///
/// Everything goes through `TerminalImageGuard` first, as it does in the app
/// (`LoggingTerminalView.dataReceived`): what has to hold is what Portside
/// runs, not SwiftTerm on its own.
///
/// Seeded, so a failure names a seed that reproduces it exactly
/// (`streamFor(seed:)`). Raw C1 bytes (0x80–0x9F) are left out of property 1
/// on purpose: SwiftTerm treats one inside an OSC or APC as text or as a
/// control depending on where a read happened to split, which this would
/// report on every run. Property 2 still covers them.
final class TerminalFuzzTests: XCTestCase {
    /// SplitMix64: tiny, fast, and the same sequence on every machine.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static let streams = 400

    // MARK: Grammar

    private static let words = ["hello", "status", "日本語", "e\u{301}", "👍🏽", "👨‍👩‍👧", "🇫🇷", "─┼─", "\t", "x"]
    private static let finals: [Character] = Array("ABCDEFGHJKLMPSTXZ@`abcdefghlmnqrstu")
    private static let modes = [1, 6, 7, 12, 25, 47, 1000, 1002, 1004, 1006, 1047, 1048, 1049, 2004, 2026]

    private static func number<R: RandomNumberGenerator>(_ g: inout R) -> String {
        switch Int.random(in: 0..<10, using: &g) {
        case 0: return ""
        case 1: return "0"
        case 2: return String(Int.random(in: 1_000...99_999_999, using: &g))
        case 3: return String(repeating: "9", count: Int.random(in: 10...30, using: &g))
        default: return String(Int.random(in: 1...200, using: &g))
        }
    }

    private static func token<R: RandomNumberGenerator>(_ g: inout R) -> String {
        let esc = "\u{1B}"
        switch Int.random(in: 0..<16, using: &g) {
        case 0, 1:
            return words.randomElement(using: &g)!
        case 2:
            return ["\r", "\n", "\r\n", "\u{8}", "\u{7}", "\u{B}", "\u{C}"].randomElement(using: &g)!
        case 3, 4:
            let count = Int.random(in: 0...4, using: &g)
            let params = (0..<count).map { _ in number(&g) }.joined(separator: ";")
            let prefix = ["", "", "?", ">", "<", "="].randomElement(using: &g)!
            let mid = Bool.random(using: &g) ? "" : [" ", "!", "$", "'"].randomElement(using: &g)!
            return "\(esc)[\(prefix)\(params)\(mid)\(finals.randomElement(using: &g)!)"
        case 5:
            let sgr = ["0", "1", "2", "3", "4", "4:3", "5", "7", "9", "22", "39", "49",
                       "38;5;\(Int.random(in: 0...300, using: &g))",
                       "48;2;\(Int.random(in: 0...300, using: &g));1;2", "38:2::10:20:30", "58;5;9"]
            let n = Int.random(in: 1...4, using: &g)
            return "\(esc)[" + (0..<n).map { _ in sgr.randomElement(using: &g)! }.joined(separator: ";") + "m"
        case 6:
            let mode = modes.randomElement(using: &g)!
            return "\(esc)[?\(mode)\(Bool.random(using: &g) ? "h" : "l")"
        case 7:
            let top = Int.random(in: 0...30, using: &g), bottom = Int.random(in: 0...30, using: &g)
            return "\(esc)[\(top);\(bottom)r"
        case 8:
            let code = [0, 1, 2, 4, 7, 8, 10, 11, 104, 133, 1337].randomElement(using: &g)!
            let body = ["title", "file://host/tmp", "A", "D;1", "1;rgb:ff/00/00", "?", "", "id=x;https://e.x"]
                .randomElement(using: &g)!
            let end = Bool.random(using: &g) ? "\u{7}" : "\(esc)\\"
            return "\(esc)]\(code);\(body)\(end)"
        case 9:
            return esc + ["7", "8", "D", "E", "M", "=", ">", "(0", "(B", ")0", "#8", "N", "O", "H", "Z"]
                .randomElement(using: &g)!
        case 10:
            return "\(esc)P$q\(["m", "r", "\"p", " q"].randomElement(using: &g)!)\(esc)\\"
        case 11:
            return "\(esc)Pq#0;2;\(Int.random(in: 0...100, using: &g));0;0#0!\(Int.random(in: 1...50, using: &g))~-~~\(esc)\\"
        case 12:
            // A sequence cut off at a random byte, the next one carrying on.
            let whole = token(&g)
            guard whole.utf8.count > 1 else { return whole }
            let cut = Int.random(in: 1..<whole.utf8.count, using: &g)
            return String(decoding: Array(whole.utf8)[..<cut], as: UTF8.self)
        case 13:
            return String(repeating: "W", count: Int.random(in: 70...200, using: &g))
        case 14:
            return "\(esc)[\(Int.random(in: 1...30, using: &g));\(Int.random(in: 1...90, using: &g))H"
        default:
            return "\(esc)[\(["J", "1J", "2J", "K", "1K", "2K", "L", "M", "P", "@", "X", "S", "T"].randomElement(using: &g)!)"
        }
    }

    static func streamFor(seed: UInt64) -> [UInt8] {
        var g = Seeded(state: seed)
        let count = Int.random(in: 5...60, using: &g)
        return Array((0..<count).map { _ in token(&g) }.joined().utf8)
    }

    // MARK: Properties

    /// A terminal fed through a fresh guard, as the app feeds one. `chunks`
    /// gives the read sizes; nil feeds everything at once.
    private final class Guarded {
        let harness = TerminalHarness()
        private var filter = TerminalImageGuard()
        func feed(_ bytes: [UInt8]) { harness.feed(Array(filter.filtered(bytes[...]))) }
        func feed(_ text: String) { feed(Array(text.utf8)) }
    }

    private func snapshot(_ h: TerminalHarness) -> [String] {
        h.screen + ["cursor \(h.cursor.x),\(h.cursor.y)", "size \(h.terminal.cols)x\(h.terminal.rows)"]
    }

    func testReadBoundariesDontChangeTheScreen() {
        var failures: [UInt64] = []
        for seed in 1...UInt64(Self.streams) {
            let stream = Self.streamFor(seed: seed)
            let whole = Guarded()
            whole.feed(stream)
            var g = Seeded(state: seed ^ 0xC0FFEE)
            let split = Guarded()
            var i = 0
            while i < stream.count {
                let n = Int.random(in: 1...17, using: &g)
                split.feed(Array(stream[i..<min(i + n, stream.count)]))
                i += n
            }
            if snapshot(whole.harness) != snapshot(split.harness) {
                failures.append(seed)
                if failures.count == 1 {
                    XCTFail("seed \(seed): the same bytes in chunks drew a different screen\n"
                            + "whole:\n\(snapshot(whole.harness).joined(separator: "\n"))\n"
                            + "split:\n\(snapshot(split.harness).joined(separator: "\n"))\n"
                            + "stream: \(String(decoding: stream, as: UTF8.self).debugDescription)")
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) of \(Self.streams) seeds differ: \(failures.prefix(20))")
    }

    func testNoStreamSwallowsWhatComesAfterIt() {
        for seed in 1...UInt64(Self.streams) {
            let g = Guarded()
            g.feed(Self.streamFor(seed: seed))
            let h = g.harness
            // Leave whatever mode the stream left: abort any sequence, reset
            // attributes, scroll region and origin mode, then write.
            g.feed("\u{18}\u{1B}\\\u{1B}[0m\u{1B}[r\u{1B}[?6l\u{1B}[?7h\u{1B}(B\u{1B}[HAFTER-\(seed)")
            if !h.screen.contains(where: { $0.contains("AFTER-\(seed)") }) {
                XCTFail("seed \(seed): text after the stream never appeared\n\(h.screen.joined(separator: "\n"))")
                return
            }
        }
    }

    /// The same grammar with raw C1 bytes and arbitrary bytes mixed in:
    /// nothing may crash or hang. (Property 1 isn't checked here: see the
    /// type's comment.)
    func testRawBytesMixedInDoNotCrash() {
        for seed in 1...UInt64(Self.streams) {
            var g = Seeded(state: seed ^ 0xBAD)
            var stream = Self.streamFor(seed: seed)
            for _ in 0..<Int.random(in: 1...20, using: &g) {
                let at = Int.random(in: 0...stream.count, using: &g)
                stream.insert(UInt8.random(in: 0x80...0xFF, using: &g), at: at)
            }
            let guarded = Guarded()
            let size = Int.random(in: 1...9, using: &g)
            var i = 0
            while i < stream.count {
                guarded.feed(Array(stream[i..<min(i + size, stream.count)]))
                i += size
            }
            guarded.feed("\u{18}ok")
        }
    }
}
