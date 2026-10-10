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

    // MARK: - Cursor movement (#32)

    /// `docker pull` and friends redraw several lines by moving the cursor
    /// up: the answer is the final screen, not every frame.
    func testAMultiLineRedrawComesBackAsItsLastFrame() {
        let frames = "layer1: Waiting\nlayer2: Waiting\n"
            + "\u{1B}[2A\u{1B}[2Klayer1: Pull complete\n\u{1B}[2Klayer2: Pull complete\n"
        XCTAssertEqual(output(frames, columns: 80), "layer1: Pull complete\nlayer2: Pull complete")
    }

    func testCursorForwardBackAndColumnAreReplayed() {
        XCTAssertEqual(output("abcdef\u{1B}[3DX", columns: 80), "abcXef")
        XCTAssertEqual(output("abc\u{1B}[1GZ", columns: 80), "Zbc")
        XCTAssertEqual(output("abc\u{1B}[GZ", columns: 80), "Zbc", "no count means 1")
        XCTAssertEqual(output("ab\u{1B}[2Cc", columns: 80), "ab  c")
        XCTAssertEqual(output("ab\u{1B}[Cc", columns: 80), "ab c")
    }

    /// Down keeps the column, as a terminal does, adding rows as needed.
    func testCursorDownKeepsTheColumn() {
        XCTAssertEqual(output("a\u{1B}[2Bb", columns: 80), "a\n\n b")
    }

    /// Up can't leave the command's own output: what was above it isn't
    /// the command's to change.
    func testCursorUpStopsAtTheFirstRow() {
        XCTAssertEqual(output("x\ny\u{1B}[9A\u{1B}[1GZ", columns: 80), "Z\ny")
    }

    /// Rows are screen rows: up from the continuation of a wrapped line lands
    /// on the row it wrapped from, and the line still reads as one line.
    func testCursorUpIntoAWrappedLine() {
        XCTAssertEqual(output("0123456789ABC\u{1B}[1A\u{1B}[1GZ", columns: 10), "Z123456789ABC")
    }

    /// A remote program decides these counts. A huge one mustn't make the
    /// capture build millions of rows or columns — a few bytes of output
    /// would otherwise hang Portside.
    func testHugeMoveCountsAreBounded() {
        let started = Date()
        let down = output("a\u{1B}[9999999999999999Bb", columns: 80)
        let right = output("a\u{1B}[9999999999999999Cb", columns: 0)
        let column = output("a\u{1B}[9999999999999999Gb", columns: 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertLessThan(down?.count ?? .max, 5_000)
        XCTAssertLessThan(right?.count ?? .max, 5_000)
        XCTAssertLessThan(column?.count ?? .max, 5_000)
    }

    /// An explicit newline starts a new line, even into a row that a wrap
    /// once made a continuation of the row above.
    func testANewlineIntoARowThatWasAWrapStartsANewLine() {
        XCTAssertEqual(output("abcdeX\u{1B}[1A\r\u{1B}[2Ktop\r\nY", columns: 5), "top\nY")
    }

    /// A progress bar that moves up and rewrites several lines repeatedly
    /// (BuildKit, cargo) ends as its last frame however many there were.
    func testManyRedrawsEndAsTheLastFrame() {
        var text = ""
        for i in 0...20 {
            if i > 0 { text += "\u{1B}[3A" }
            text += "\u{1B}[2Ka \(i)\n\u{1B}[2Kb \(i)\n\u{1B}[2Kc \(i)\n"
        }
        XCTAssertEqual(output(text, columns: 80), "a 20\nb 20\nc 20")
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

    /// Output past the cap keeps its end and says it was cut. (The buffer
    /// now trims only once it has doubled instead of on every byte; measured
    /// in a debug build that was ~1.5x on 8 MB, not a stall, so this checks
    /// what's kept rather than a timing.)
    func testAHugeOutputKeepsTheEndAndSaysItWasCut() {
        let line = Array(String(repeating: "y", count: 99).utf8) + [0x0A]
        let chunk = Array(repeating: line, count: 100).flatMap { $0 }   // 10 KB
        var big = CommandOutputCapture()
        big.consume(ArraySlice(Array("\u{1B}]133;C\u{07}".utf8)))
        for _ in 0..<200 { big.consume(ArraySlice(chunk)) }               // 2 MB
        big.consume(ArraySlice(Array("the-end\n\u{1B}]133;D;0\u{07}".utf8)))
        let done = big.completed.last
        XCTAssertEqual(done?.truncated, true)
        XCTAssertTrue(done?.output.hasSuffix("the-end") == true)
        XCTAssertLessThanOrEqual(done?.output.utf8.count ?? .max, CommandOutputCapture.maxBytesPerCommand)
        XCTAssertGreaterThan(done?.output.utf8.count ?? 0, CommandOutputCapture.maxBytesPerCommand - 200,
                             "keeps a full cap's worth, not less")
    }

    // MARK: Prompt-only (sh, ash, dash)

    /// What the prompt-only integration's PS1 prints: the last status, the
    /// prompt start, the prompt itself, the prompt end.
    private func prompt(_ status: Int) -> String { osc("D;\(status)") + osc("A") + "/ # " + osc("B") }

    func testAPromptOnlyShellRecordsTheTypedLineAndItsOutput() {
        var c = CommandOutputCapture()
        // The injection line ends by printing a B of its own, so the first
        // new prompt's D finds nothing typed.
        feed(&c, osc("B") + "\r\n" + prompt(0) + "echo hi\r\nhi\r\n" + prompt(0) + "false\r\n" + prompt(1))
        XCTAssertEqual(c.completed.map(\.command), ["echo hi", "false"])
        XCTAssertEqual(c.completed.map(\.output), ["hi", ""])
        XCTAssertEqual(c.completed.map(\.exitCode), [0, 1])
        XCTAssertTrue(c.completed.allSatisfy(\.inferred))
        XCTAssertEqual(c.finishedTotal, 2, "a wait sees each one finish")
    }

    func testAnEmptyReturnAtAPromptOnlyPromptIsNoCommand() {
        var c = CommandOutputCapture()
        feed(&c, osc("B") + prompt(0) + "\r\n" + prompt(0) + "\r\n" + prompt(0))
        XCTAssertTrue(c.completed.isEmpty, "\(c.completed)")
        XCTAssertEqual(c.finishedTotal, 0)
    }

    /// Line editing at the prompt is replayed, so the command is what was
    /// finally entered, not every keystroke.
    func testAPromptOnlyCommandIsTheLineAsFinallyTyped() {
        var c = CommandOutputCapture()
        feed(&c, osc("B") + prompt(0) + "ecoh\u{8}\u{8}ho hi\r\nhi\r\n" + prompt(0))
        XCTAssertEqual(c.completed.first?.command, "echo hi")
    }

    /// A full integration (bash, zsh) never sends B, so its commands aren't
    /// marked inferred and nothing between them is read as one.
    func testAFullIntegrationIsNotPromptOnly() {
        var c = CommandOutputCapture()
        feed(&c, osc("A") + "$ " + osc("C") + osc("E;\(Data("ls".utf8).base64EncodedString())") + "a b\r\n"
             + osc("D;0") + osc("A") + "$ ")
        XCTAssertEqual(c.completed.count, 1)
        XCTAssertFalse(c.completed[0].inferred)
    }
}
