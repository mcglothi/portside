import AppKit
import XCTest
@testable import Portside

/// Guards the MultiExec mirroring contract on LoggingTerminalView: only
/// genuine user input may reach `onUserInput`. Programmatic sends (broadcast
/// bar, macros), peer-mirrored input, and the terminal's own query responses
/// must not — each of those re-entering the mirror means commands running
/// N× per host or DA/DSR garbage typed into peers.
final class MultiExecMirrorTests: XCTestCase {
    private func makeView() -> (view: LoggingTerminalView, mirrored: () -> [UInt8]) {
        let view = LoggingTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        var captured: [UInt8] = []
        view.onUserInput = { captured.append(contentsOf: $0) }
        return (view, { captured })
    }

    func testUserInputPathMirrors() {
        let (view, mirrored) = makeView()
        // send(txt:) funnels through the same delegate send(source:data:)
        // that keyboard/paste input uses.
        view.send(txt: "w\r")
        XCTAssertEqual(mirrored(), Array("w\r".utf8))
    }

    func testProgrammaticSendDoesNotMirror() {
        let (view, mirrored) = makeView()
        view.sendProgrammatic("uptime\r")
        XCTAssertTrue(mirrored().isEmpty,
                      "broadcast/macro sends must not re-mirror — each host would run the command N times")
    }

    func testMirroredInputDoesNotMirrorAgain() {
        let (view, mirrored) = makeView()
        let bytes = Array("ls\r".utf8)
        view.sendMirroredInput(bytes[...])
        XCTAssertTrue(mirrored().isEmpty, "peer-mirrored input must not fan back out (feedback loop)")
    }

    func testTerminalQueryResponsesDoNotMirror() {
        let (view, mirrored) = makeView()
        // Simulate the terminal auto-answering a host query (e.g. DA/DSR),
        // which SwiftTerm routes through send(source: Terminal, data:).
        let response = Array("\u{1B}[?64;1;2c".utf8)
        view.send(source: view.getTerminal(), data: response[...])
        XCTAssertTrue(mirrored().isEmpty,
                      "terminal auto-responses are not user input; mirroring them types garbage into peers")
    }

    func testSuppressionIsScopedNotSticky() {
        let (view, mirrored) = makeView()
        view.sendProgrammatic("setup\r")
        view.send(txt: "y")
        XCTAssertEqual(mirrored(), Array("y".utf8),
                       "user input right after a programmatic send must still mirror")
    }
}
