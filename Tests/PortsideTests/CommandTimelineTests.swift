import Foundation
import XCTest
@testable import Portside

final class CommandTimelineTests: XCTestCase {

    private func bytes(_ string: String) -> ArraySlice<UInt8> {
        Array(string.utf8)[...]
    }

    private func b64(_ string: String) -> String {
        Data(string.utf8).base64EncodedString()
    }

    /// ESC ] … BEL
    private func osc(_ body: String) -> String { "\u{1B}]\(body)\u{07}" }

    // MARK: - Parser

    func testParsesEachMarkerType() {
        var parser = OSC133Parser()
        let stream = osc("133;A") + osc("133;C") + osc("133;E;\(b64("ls -la"))") + osc("133;D;0")
        XCTAssertEqual(parser.consume(bytes(stream)), [
            .promptStart, .commandStart, .commandText("ls -la"), .commandFinished(exitCode: 0)
        ])
    }

    func testAcceptsStTerminatorAsWellAsBel() {
        var parser = OSC133Parser()
        // ESC \ instead of BEL — both are legal OSC terminators and shells
        // differ on which they emit.
        XCTAssertEqual(parser.consume(bytes("\u{1B}]133;C\u{1B}\\")), [.commandStart])
    }

    /// The reason this is a byte-level state machine: a marker can arrive in
    /// pieces, and a line-based parser would miss it entirely.
    func testMarkerSplitAcrossReadsIsStillFound() {
        var parser = OSC133Parser()
        XCTAssertTrue(parser.consume(bytes("\u{1B}]13")).isEmpty)
        XCTAssertTrue(parser.consume(bytes("3;D;")).isEmpty)
        XCTAssertEqual(parser.consume(bytes("7\u{07}")), [.commandFinished(exitCode: 7)])
    }

    func testCommandTextSurvivesSemicolonsAndNewlines() {
        // Base64 is why: a raw command containing ';' would be split by the
        // OSC parameter separator.
        var parser = OSC133Parser()
        let command = "for i in 1 2; do echo $i; done"
        XCTAssertEqual(
            parser.consume(bytes(osc("133;E;\(b64(command))"))),
            [.commandText(command)]
        )
    }

    func testOtherOSCSequencesAreIgnored() {
        var parser = OSC133Parser()
        // OSC 7 (cwd) and OSC 8 (hyperlink) share this stream.
        let stream = osc("7;file://host/home/tim") + osc("8;;https://example.com") + osc("133;C")
        XCTAssertEqual(parser.consume(bytes(stream)), [.commandStart])
    }

    func testPlainOutputProducesNoMarkers() {
        var parser = OSC133Parser()
        XCTAssertTrue(parser.consume(bytes("total 42\nrw-r--r-- file.txt\n")).isEmpty)
    }

    func testBareFinishMarkerReportsUnknownExitCode() {
        var parser = OSC133Parser()
        XCTAssertEqual(parser.consume(bytes(osc("133;D"))), [.commandFinished(exitCode: nil)])
    }

    func testUnterminatedPayloadDoesNotGrowForever() {
        var parser = OSC133Parser()
        let flood = String(repeating: "x", count: 20_000)
        XCTAssertTrue(parser.consume(bytes("\u{1B}]133;E;" + flood)).isEmpty)
        // Parser recovered, so a subsequent well-formed marker is still seen.
        XCTAssertEqual(parser.consume(bytes(osc("133;C"))), [.commandStart])
    }

    /// Captured verbatim from a real zsh running the shipped snippet, ST
    /// terminator on the OSC 7 and all. Synthetic fixtures can drift from what
    /// shells actually emit; this one can't.
    func testRealZshOutputIsParsedEndToEnd() {
        let real = "\u{1B}]133;C\u{07}"
            + "\u{1B}]133;E;Z3JlcCAtciBmb287IGxz\u{07}"
            + "\u{1B}]133;D;3\u{07}"
            + "\u{1B}]7;file://Newton/Users/mcglothi/code\u{1B}\\"
            + "\u{1B}]133;A\u{07}"

        var timeline = CommandTimeline()
        let start = Date(timeIntervalSince1970: 2_000)
        let done = timeline.consume(bytes(real), now: start)

        XCTAssertEqual(done.count, 1)
        XCTAssertEqual(done[0].command, "grep -r foo; ls",
                       "the semicolon must survive base64 round-tripping")
        XCTAssertEqual(done[0].exitCode, 3)
        XCTAssertEqual(done[0].succeeded, false)
        XCTAssertNil(timeline.runningCommand, "the trailing prompt marker leaves nothing open")
    }

    // MARK: - Timeline

    func testCompletedCommandCarriesTextTimingAndExitCode() {
        var timeline = CommandTimeline()
        let start = Date(timeIntervalSince1970: 1_000)
        let end = start.addingTimeInterval(3)

        XCTAssertTrue(timeline.consume(bytes(osc("133;C") + osc("133;E;\(b64("make build"))")), now: start).isEmpty)
        let done = timeline.consume(bytes(osc("133;D;0")), now: end)

        XCTAssertEqual(done.count, 1)
        XCTAssertEqual(done[0].command, "make build")
        XCTAssertEqual(done[0].startedAt, start)
        XCTAssertEqual(done[0].finishedAt, end)
        XCTAssertEqual(done[0].exitCode, 0)
        XCTAssertEqual(done[0].duration, 3)
        XCTAssertEqual(done[0].succeeded, true)
    }

    func testFailedCommandIsRecordedAsSuch() {
        var timeline = CommandTimeline()
        _ = timeline.consume(bytes(osc("133;C") + osc("133;E;\(b64("false"))")))
        let done = timeline.consume(bytes(osc("133;D;1")))
        XCTAssertEqual(done.first?.exitCode, 1)
        XCTAssertEqual(done.first?.succeeded, false)
    }

    func testFinishWithoutAStartIsDiscarded() {
        // The first prompt after login reports the *previous* shell's exit
        // status; inventing a command for it would be fiction.
        var timeline = CommandTimeline()
        XCTAssertTrue(timeline.consume(bytes(osc("133;D;0"))).isEmpty)
    }

    func testSecondStartClosesAnUnterminatedCommand() {
        // Shells miss a D when a command is interrupted; the earlier command
        // should still be reported rather than vanishing.
        var timeline = CommandTimeline()
        _ = timeline.consume(bytes(osc("133;C") + osc("133;E;\(b64("sleep 100"))")))
        let closed = timeline.consume(bytes(osc("133;C") + osc("133;E;\(b64("whoami"))")))

        XCTAssertEqual(closed.count, 1)
        XCTAssertEqual(closed[0].command, "sleep 100")
        XCTAssertNil(closed[0].exitCode, "it never reported one")
        XCTAssertEqual(timeline.runningCommand?.command, "whoami")
    }

    func testRunningCommandIsExposedWhileInFlight() {
        var timeline = CommandTimeline()
        _ = timeline.consume(bytes(osc("133;C") + osc("133;E;\(b64("tail -f log"))")))
        XCTAssertEqual(timeline.runningCommand?.command, "tail -f log")
        XCTAssertNil(timeline.runningCommand?.finishedAt)

        _ = timeline.consume(bytes(osc("133;D;0")))
        XCTAssertNil(timeline.runningCommand)
    }

    func testEventsCarryTheHostTheyRanOn() {
        let host = UUID()
        var timeline = CommandTimeline(entryID: host)
        _ = timeline.consume(bytes(osc("133;C")))
        let done = timeline.consume(bytes(osc("133;D;0")))
        XCTAssertEqual(done.first?.entryID, host)
    }
}
