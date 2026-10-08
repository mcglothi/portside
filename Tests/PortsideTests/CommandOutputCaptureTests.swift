import XCTest
@testable import Portside

/// The bytes between a command's OSC 133 start and finish marks are its
/// output. Fed as a real stream would arrive: split anywhere, escapes inline.
final class CommandOutputCaptureTests: XCTestCase {
    private func osc(_ body: String) -> String { "\u{1B}]133;\(body)\u{07}" }
    private func feed(_ capture: inout CommandOutputCapture, _ s: String, chunk: Int = 3) {
        let bytes = Array(s.utf8)
        var i = 0
        while i < bytes.count {
            capture.consume(bytes[i..<min(i + chunk, bytes.count)])
            i += chunk
        }
    }

    func testOutputBetweenMarksWithEscapesStripped() {
        var c = CommandOutputCapture()
        let text = Data("df -h".utf8).base64EncodedString()
        feed(&c, "prompt$ " + osc("C") + osc("E;\(text)") + "\u{1B}[1mFilesystem\u{1B}[0m  Size\r\n/dev/disk1  500G\r\n"
             + osc("D;0") + osc("A") + "prompt$ ")
        XCTAssertEqual(c.completed.count, 1)
        let cmd = c.completed[0]
        XCTAssertEqual(cmd.command, "df -h")
        XCTAssertEqual(cmd.exitCode, 0)
        XCTAssertEqual(cmd.output, "Filesystem  Size\n/dev/disk1  500G")
        XCTAssertFalse(cmd.output.contains("prompt$"), "the prompt is not output")
    }

    func testRunningCommandShowsOutputSoFarAndFailuresKeepTheirCode() {
        var c = CommandOutputCapture()
        feed(&c, osc("C") + "partial line\n")
        XCTAssertEqual(c.recent.first?.finished, false)
        XCTAssertEqual(c.recent.first?.output, "partial line")
        feed(&c, "no such file\n" + osc("D;2"))
        XCTAssertEqual(c.recent.first?.exitCode, 2)
        XCTAssertEqual(c.recent.first?.finished, true)
    }

    /// Issue #24: a wait ends when a command finishes, and by then the next
    /// one can already be running. What the agent waited for is the first to
    /// finish after it asked, not the newest record.
    func testTheCommandAWaitWasForIsTheFirstToFinishAfterIt() {
        func e(_ s: String) -> String { osc("E;" + Data(s.utf8).base64EncodedString()) }
        var c = CommandOutputCapture()
        feed(&c, osc("C") + e("earlier") + osc("D;0"))
        let baseline = c.finishedTotal
        XCTAssertNil(c.firstFinished(after: baseline), "nothing has finished since")

        feed(&c, osc("C") + e("hostname") + "web1\n" + osc("D;0") + osc("C") + e("next") + "busy\n")
        XCTAssertEqual(c.recent.first?.command, "next", "the head of the list is already the next one")
        XCTAssertEqual(c.recent.first?.finished, false)
        XCTAssertEqual(c.firstFinished(after: baseline)?.command, "hostname")
        XCTAssertEqual(c.firstFinished(after: baseline)?.exitCode, 0)
        XCTAssertEqual(c.firstFinished(after: baseline)?.output, "web1")

        // Gone from the kept few: nothing, rather than a different command.
        for i in 0..<CommandOutputCapture.kept { feed(&c, osc("C") + e("n\(i)") + osc("D;0")) }
        XCTAssertNil(c.firstFinished(after: baseline))
    }

    func testLongOutputKeepsTheTailAndOnlyTheLastFew() {
        var c = CommandOutputCapture()
        let long = (1...6000).map { "line \($0)" }.joined(separator: "\n")
        feed(&c, osc("C") + long + "\n" + osc("D;0"), chunk: 4096)
        let out = c.completed[0]
        XCTAssertTrue(out.truncated)
        XCTAssertTrue(out.output.hasSuffix("line 6000"), "the end is where errors and summaries are")
        for n in 1...7 { feed(&c, osc("C") + "run \(n)\n" + osc("D;0")) }
        XCTAssertEqual(c.completed.count, CommandOutputCapture.kept)
        XCTAssertEqual(c.recent.first?.output, "run 7")
    }

    // MARK: Line editing replayed, not dropped

    private func output(_ body: String, columns: Int) -> String? {
        var c = CommandOutputCapture()
        c.columns = columns
        feed(&c, osc("C") + body + osc("D;0"))
        return c.completed.first?.output
    }

    /// Once a long line has wrapped, readline returns to the start of the new
    /// row and rewrites the character already there. With CR dropped that read
    /// as a doubled character at every wrap (`MNN`).
    func testReadlineRewriteAtAWrapIsNotDoubled() {
        XCTAssertEqual(output("0123456789A\rABCD", columns: 10), "0123456789ABCD")
        // Bytes as bash 4.4 sent them in a 20-column pty.
        XCTAssertEqual(output("$ echo ABCDEFGHIJKLMN\rNOPQRSTUVWXYZabcdefgh\rhij", columns: 20),
                       "$ echo ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij")
    }

    /// A row filled exactly hasn't wrapped yet — the terminal defers that to the
    /// next character — so CR there goes back to the start of the same row.
    func testCarriageReturnAtAFullRowStaysOnThatRow() {
        XCTAssertEqual(output("0123456789\rX", columns: 10), "X123456789")
    }

    func testProgressRedrawKeepsTheLastFrame() {
        XCTAssertEqual(output(" 10%\r 50%\r100%\r\ndone\r\n", columns: 0), "100%\ndone")
        XCTAssertEqual(output("downloading\r\u{1B}[Kok", columns: 80), "ok", "erase-in-line clears the tail")
        XCTAssertEqual(output("abc\u{8}d", columns: 80), "abd")
    }

    /// The log keeps its own behaviour: it has no width to replay against.
    func testTheLogsStripperStillDropsLineEditing() {
        var plain = ANSIStripper()
        XCTAssertEqual(plain.strip(Array("a\rb\u{8}c\u{1B}[Kd".utf8)), Array("abcd".utf8))
    }

    // MARK: Erase-in-line modes (PR #30 review)

    /// Each EL mode keeps its own meaning. Collapsing them all to "erase to end"
    /// meant a whole-line erase sent with the cursor at the end of the line
    /// cleared nothing, and a shorter redraw left the old tail behind.
    func testWholeLineEraseClearsTheLineInEitherOrder() {
        XCTAssertEqual(output("downloading 100 files\u{1B}[2K\rdone", columns: 80), "done")
        XCTAssertEqual(output("downloading 100 files\r\u{1B}[2Kdone", columns: 80), "done")
    }

    func testEraseToStartBlanksOnlyTheLeftPart() {
        XCTAssertEqual(output("first\nabcdef\u{8}\u{8}\u{1B}[1K", columns: 80), "first\n     f")
    }

    func testEraseToEndIsUnchangedSpelledEitherWay() {
        XCTAssertEqual(output("abcdef\u{8}\u{8}\u{1B}[K", columns: 80), "abcd")
        XCTAssertEqual(output("abcdef\u{8}\u{8}\u{1B}[0K", columns: 80), "abcd")
    }

    /// A position one row's width in is either the end of a full row (wrap
    /// pending) or the start of the next; a CR that lands on a wrapped row's
    /// start must leave the cursor there, not send the next CR back a row.
    func testCarriageReturnOnAWrappedRowStaysOnThatRow() {
        XCTAssertEqual(output("0123456789ABC\r\rX", columns: 10), "0123456789XBC")
        XCTAssertEqual(output("0123456789ABC\r\u{1B}[2KX", columns: 10), "0123456789X")
    }

    /// A CSI aborted by CAN leaves no parameter behind for the next one.
    func testAnAbortedSequenceDoesntChangeTheNextErasesMode() {
        XCTAssertEqual(output("first\nabcdef\u{8}\u{8}\u{1B}[2\u{18}\u{1B}[K", columns: 80), "first\nabcd")
    }

    /// Typing switched on mid-command: the capture never saw it start, but its
    /// finish still counts, with what it printed since — and nothing from the
    /// prompt that follows.
    func testACommandAlreadyRunningIsRecordedWhenItFinishes() {
        var c = CommandOutputCapture()
        feed(&c, "still going\nall done\n" + osc("D;0") + osc("A") + "prompt$ ")
        XCTAssertEqual(c.completed.count, 1)
        XCTAssertEqual(c.completed.first?.command, CommandOutputCapture.alreadyRunning)
        XCTAssertEqual(c.completed.first?.output, "still going\nall done")
        XCTAssertEqual(c.firstFinished(after: 0)?.exitCode, 0)
        // From here every command is seen starting; a stray finish adds nothing.
        feed(&c, osc("D;1"))
        XCTAssertEqual(c.completed.count, 1)
    }
}

