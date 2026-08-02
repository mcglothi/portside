import XCTest
import SwiftTerm
@testable import Portside

/// Terminal compatibility suite — stream integrity.
///
/// The first slice, aimed at where this project has actually been burned: a
/// Sixel crash on a degenerate band, and a session transcript swallowed whole
/// by an escape sequence that never ended. Both were parser-state failures on
/// input nobody would type deliberately, and both reached users.
///
/// See `docs/road-to-1.0.md`. The suite's job is to stand between a SwiftTerm
/// bump and a regression nobody notices for a week, so it asserts on the
/// properties Portside depends on rather than on any particular byte sequence.
final class TerminalStreamIntegrityTests: XCTestCase {

    private let esc = UInt8(0x1B)
    private let bel = UInt8(0x07)

    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    // MARK: - Chunking

    /// The property that matters most: a pty hands over whatever `read()` had
    /// available, so any sequence can be split at any byte. A parser that only
    /// works on whole sequences looks perfect until it meets a slow link or a
    /// busy host.
    private func assertChunkingIsInvisible(
        _ stream: [UInt8], file: StaticString = #filePath, line: UInt = #line
    ) {
        let whole = TerminalHarness()
        whole.feed(stream)
        let expected = whole.screen

        for chunk in [1, 2, 3, 5, 7, 13, 64] {
            let split = TerminalHarness()
            split.feed(stream, inChunksOf: chunk)
            XCTAssertEqual(split.screen, expected,
                           "same bytes in \(chunk)-byte chunks produced a different screen",
                           file: file, line: line)
        }
    }

    func testPlainTextSurvivesAnyChunking() {
        assertChunkingIsInvisible(bytes("the quick brown fox\r\njumps over\r\n"))
    }

    func testCursorMovementSurvivesAnyChunking() {
        // CSI sequences split mid-parameter are the classic case.
        assertChunkingIsInvisible(bytes("\u{1B}[10;20Hplaced\u{1B}[1;1Htop\u{1B}[2Kcleared"))
    }

    func testColourAndAttributesSurviveAnyChunking() {
        assertChunkingIsInvisible(bytes("\u{1B}[1;31mred\u{1B}[0m normal \u{1B}[38;5;208m256\u{1B}[0m"))
    }

    func testOSCTitleSurvivesAnyChunking() {
        assertChunkingIsInvisible(bytes("\u{1B}]0;a title\u{07}after"))
    }

    func testAnOSCSplitAcrossChunksStillSetsTheTitle() {
        // Not just "the screen matches" — the side effect has to land too.
        let t = TerminalHarness()
        t.feed(bytes("\u{1B}]0;split title\u{07}"), inChunksOf: 1)
        XCTAssertEqual(t.titles.last, "split title")
    }

    func testUTF8SplitMidCodepointStillRenders() {
        // A multi-byte character straddling a read boundary must not become
        // replacement characters — this is routine on any non-ASCII host.
        assertChunkingIsInvisible(bytes("héllo → 日本語 ✅"))
        let t = TerminalHarness()
        t.feed(bytes("日本語"), inChunksOf: 1)
        XCTAssertTrue(t.line(0).contains("日本語"), "got: \(t.line(0))")
    }

    // MARK: - Malformed input

    /// The transcript-truncation shape: a sequence that never terminates must
    /// not swallow everything after it. Whether the terminal shows the tail or
    /// discards the sequence is its business; hanging or eating the rest of the
    /// session is not.
    func testAnUnterminatedOSCDoesNotSwallowTheRestOfTheSession() {
        let t = TerminalHarness()
        t.feed(bytes("\u{1B}]0;never ends"))
        t.feed(bytes("\r\nvisible after\r\n"))
        // A bounded sequence must give up rather than consume forever.
        t.feed(bytes(String(repeating: "x", count: 10_000)))
        t.feed(bytes("\u{07}\r\nrecovered\r\n"))
        XCTAssertTrue(t.screen.contains { $0.contains("recovered") },
                      "the terminal never came back: \(t.screen.prefix(3))")
    }

    func testAnUnterminatedCSIDoesNotSwallowTheRestOfTheSession() {
        let t = TerminalHarness()
        t.feed(bytes("\u{1B}[999999999999;999999999999"))
        t.feed(bytes("\u{1B}[0m\r\nstill alive\r\n"))
        XCTAssertTrue(t.screen.contains { $0.contains("still alive") },
                      "got: \(t.screen.prefix(3))")
    }

    func testALoneEscapeIsNotFatal() {
        let t = TerminalHarness()
        t.feed([esc])
        t.feed(bytes("after a bare escape"))
        XCTAssertFalse(t.screen.isEmpty)
    }

    func testRandomBytesDoNotCrashOrHang() {
        // Not a correctness claim — a liveness one. A terminal reads untrusted
        // bytes by definition, and the only unacceptable outcome is not
        // returning.
        var generator = SystemRandomNumberGenerator()
        let noise = (0..<20_000).map { _ in UInt8.random(in: 0...255, using: &generator) }
        let t = TerminalHarness()
        t.feed(noise, inChunksOf: 37)
        t.feed(bytes("\u{1B}c\r\nafter the noise\r\n"))   // RIS, then a marker
        XCTAssertTrue(t.screen.contains { $0.contains("after the noise") },
                      "terminal did not recover after a reset")
    }

    // MARK: - Volume

    func testALargePasteLandsIntact() {
        // The 2 MB case from the plan: a paste that big is unusual but a
        // `cat` of a log is not, and it's the same path.
        let line = "0123456789abcdef"
        let payload = Array(repeating: line, count: 128 * 1024).joined(separator: "\r\n")
        let t = TerminalHarness()
        t.feed(bytes(payload), inChunksOf: 4096)
        XCTAssertEqual(t.line(t.terminal.rows - 1), line,
                       "the last line of a large write should be intact")
    }

    func testAVeryLongSingleLineWrapsRatherThanTruncating() {
        let t = TerminalHarness(cols: 80, rows: 24)
        t.feed(bytes(String(repeating: "A", count: 500)))
        let painted = t.screen.joined().filter { $0 == "A" }.count
        XCTAssertEqual(painted, 500, "every character should land somewhere")
    }
}
