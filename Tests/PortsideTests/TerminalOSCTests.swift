import XCTest
import SwiftTerm
@testable import Portside

/// Terminal compatibility suite — the OSC sequences Portside itself consumes.
///
/// Different from the rest of the suite: these aren't general correctness, they
/// are the contracts Portside's own features are built on. The SFTP browser
/// follows the shell's directory through OSC 7. Command history and the
/// post-connect gate read OSC 133. The paste confirmation depends on bracketed
/// paste framing the mirrored bytes.
///
/// Each of those breaks quietly if the terminal's handling shifts under a
/// dependency bump — the browser opens in the wrong directory, history stops
/// recording, a command lands at a login prompt — so they're worth pinning
/// separately from "does the parser work".
final class TerminalOSCTests: XCTestCase {

    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    // MARK: - OSC 7: current directory

    func testOSC7ReportsTheDirectoryTheSFTPBrowserFollows() {
        let t = TerminalHarness()
        t.feed("\u{1B}]7;file://host/var/log\u{07}")
        XCTAssertEqual(t.reportedDirectory, "file://host/var/log")
    }

    func testOSC7SurvivesBeingSplitAcrossReads() {
        // The browser opening in the wrong directory was a real bug once. A
        // path arriving in two reads must still land.
        let t = TerminalHarness()
        t.feed(bytes("\u{1B}]7;file://host/deep/nested/path\u{07}"), inChunksOf: 1)
        XCTAssertEqual(t.reportedDirectory, "file://host/deep/nested/path")
    }

    func testTheLastOSC7Wins() {
        let t = TerminalHarness()
        t.feed("\u{1B}]7;file://host/first\u{07}")
        t.feed("\u{1B}]7;file://host/second\u{07}")
        XCTAssertEqual(t.reportedDirectory, "file://host/second")
    }

    func testOSC7AcceptsTheStringTerminatorAsWellAsBEL()  {
        // Shells emit either `BEL` or `ESC \`; both are legal.
        let t = TerminalHarness()
        t.feed("\u{1B}]7;file://host/via-st\u{1B}\\")
        XCTAssertEqual(t.reportedDirectory, "file://host/via-st")
    }

    // MARK: - Titles

    func testOSC0SetsTheTitleTheTabBarShows() {
        let t = TerminalHarness()
        t.feed("\u{1B}]0;mcglothi@newton\u{07}")
        XCTAssertEqual(t.titles.last, "mcglothi@newton")
    }

    func testATitleContainingUTF8Survives() {
        let t = TerminalHarness()
        t.feed("\u{1B}]0;~/código/日本\u{07}")
        XCTAssertEqual(t.titles.last, "~/código/日本")
    }

    // MARK: - OSC 133, via Portside's own parser
    //
    // SwiftTerm doesn't implement 133, so Portside scans the byte stream for it
    // (`OSC133Parser`). These check the parser against the same chunking the
    // terminal has to survive, because it reads the *same* stream.

    func testOSC133PromptAndCommandMarkersAreFound() {
        var parser = OSC133Parser()
        let stream = bytes("\u{1B}]133;A\u{07}$ \u{1B}]133;C\u{07}uptime\r\n\u{1B}]133;D;0\u{07}")
        let seen = parser.consume(stream[...])
        XCTAssertTrue(seen.contains(.promptStart), "prompt marker missed: \(seen)")
        XCTAssertTrue(seen.contains(.commandStart), "command marker missed: \(seen)")
        XCTAssertTrue(seen.contains(.commandFinished(exitCode: 0)), "exit status missed: \(seen)")
    }

    func testOSC133MarkersSurviveByteAtATimeDelivery() {
        // The post-connect gate and command history both depend on these
        // landing regardless of how the pty chunks them.
        let stream = bytes("\u{1B}]133;A\u{07}")
        var parser = OSC133Parser()
        var seen: [OSC133Parser.Marker] = []
        for byte in stream { seen += parser.consume([byte][...]) }
        XCTAssertTrue(seen.contains(.promptStart),
                      "a prompt marker delivered one byte at a time was missed")
    }

    // MARK: - Bracketed paste

    func testBracketedPasteModeIsEnteredAndLeft() {
        let t = TerminalHarness()
        XCTAssertFalse(t.terminal.bracketedPasteMode, "off by default")
        t.feed("\u{1B}[?2004h")
        XCTAssertTrue(t.terminal.bracketedPasteMode, "shells enable this at the prompt")
        t.feed("\u{1B}[?2004l")
        XCTAssertFalse(t.terminal.bracketedPasteMode)
    }

    func testBracketedPasteModeSurvivesChunking() {
        let t = TerminalHarness()
        t.feed(bytes("\u{1B}[?2004h"), inChunksOf: 1)
        XCTAssertTrue(t.terminal.bracketedPasteMode,
                      "the mode set that frames every paste must not depend on read sizes")
    }

    // MARK: - Mouse reporting

    func testMouseModeChangesAreTracked() {
        // Portside's selection and click-to-focus behaviour differ when the
        // host has grabbed the mouse (vim, tmux, less).
        let t = TerminalHarness()
        let before = t.terminal.mouseMode
        t.feed("\u{1B}[?1000h")
        XCTAssertNotEqual(t.terminal.mouseMode, before, "the host asked for mouse events")
        t.feed("\u{1B}[?1000l")
    }
}
