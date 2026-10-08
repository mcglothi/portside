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
}
