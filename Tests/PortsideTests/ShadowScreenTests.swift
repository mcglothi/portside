import AppKit
import SwiftTerm
import XCTest
@testable import Portside

/// Agent screen reads come from Portside's own copy of the terminal when it
/// has seen the whole session (#69): under SwiftTerm v2 the view's terminal,
/// with its scrollback, is out of reach. For that to be safe the copy has to
/// read exactly as the view does.
@MainActor
final class ShadowScreenTests: XCTestCase {
    private func view() -> LoggingTerminalView {
        LoggingTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
    }

    private func feed(_ v: LoggingTerminalView, _ bytes: [UInt8], chunk: Int = 64) {
        var i = 0
        while i < bytes.count {
            v.dataReceived(slice: bytes[i..<min(i + chunk, bytes.count)])
            i += chunk
        }
    }

    /// The fuzz suite's streams plus scrolling output: the shadow's text,
    /// scrollback included, is the view's, stream for stream — for every
    /// stream without an image (see the next test for those).
    func testTheShadowReadsExactlyAsTheView() throws {
        var differ: [UInt64] = [], compared = 0
        for seed in 1...UInt64(1000) {
            var stream = TerminalFuzzTests.streamFor(seed: seed)
            guard !Self.drawsAnImage(stream) else { continue }
            compared += 1
            let v = view()
            v.setShadowScreen(true)
            let shadow = try XCTUnwrap(v.shadowScreen)
            XCTAssertTrue(shadow.complete)
            stream += Array((1...120).map { "line \($0) of seed \(seed)\r\n" }.joined().utf8)
            feed(v, stream, chunk: Int(seed % 13) + 1)
            if AgentController.screenLines(v.getTerminal()) != AgentController.screenLines(shadow.terminal) {
                differ.append(seed)
            }
        }
        XCTAssertGreaterThan(compared, 150)
        XCTAssertTrue(differ.isEmpty, "the shadow read differently for seeds \(differ.prefix(10))")
    }

    /// The one known difference: the view makes room for an image by adding
    /// rows to the buffer, sized from its fonts and display, and the headless
    /// shadow can't. So around an image the shadow has fewer blank rows and
    /// its text sits higher. Images carry no text for an agent to read, and
    /// matching the view's sizing would mean copying its layout arithmetic.
    /// Pinned so a change in either direction is noticed.
    func testImagesAreTheKnownDifference() throws {
        let v = view()
        v.setShadowScreen(true)
        let sixel = "\u{1b}Pq#0;2;100;0;0#0!40~-!40~-!40~\u{1b}\\"
        feed(v, Array("above\r\n\(sixel)\r\nbelow\r\n".utf8))
        let viewText = AgentController.screenLines(v.getTerminal())
        let shadowText = AgentController.screenLines(try XCTUnwrap(v.shadowScreen).terminal)
        XCTAssertNotEqual(viewText, shadowText, "if these match, the shadow now handles images: tighten the test above")
        func words(_ t: String) -> [String] { t.split(whereSeparator: \.isWhitespace).map(String.init) }
        XCTAssertEqual(words(viewText), words(shadowText), "the text itself is the same")
    }

    static func drawsAnImage(_ bytes: [UInt8]) -> Bool {
        let text = String(decoding: bytes, as: UTF8.self)
        return text.contains("\u{1b}Pq") || text.contains("\u{1b}_G") || text.contains("1337;File")
    }

    func testScrollbackIsThere() throws {
        let v = view()
        v.setShadowScreen(true)
        feed(v, Array((1...300).map { "row \($0)\r\n" }.joined().utf8))
        let text = AgentController.screenLines(v.screenSource)
        XCTAssertTrue(text.contains("row 1\n"), "scrolled-off lines are kept")
        XCTAssertTrue(text.contains("row 300"))
        XCTAssertTrue(v.screenSource === v.shadowScreen?.terminal, "reads come from the shadow")
    }

    /// Switched on after output, it hasn't seen the start, so reads stay on
    /// the view's own terminal.
    func testALateShadowIsntReadFrom() throws {
        let v = view()
        feed(v, Array("before\r\n".utf8))
        v.setShadowScreen(true)
        XCTAssertEqual(v.shadowScreen?.complete, false)
        XCTAssertTrue(v.screenSource === v.getTerminal())
    }

    func testItFollowsTheViewsSize() throws {
        let v = view()
        v.setShadowScreen(true)
        v.getTerminal().resize(cols: 91, rows: 33)
        v.sizeChanged(source: v, newCols: 91, newRows: 33)
        XCTAssertEqual(v.shadowScreen?.terminal.cols, 91)
        XCTAssertEqual(v.shadowScreen?.terminal.rows, 33)
    }

    func testTurningItOffDropsIt() {
        let v = view()
        v.setShadowScreen(true)
        v.setShadowScreen(false)
        XCTAssertNil(v.shadowScreen)
        XCTAssertTrue(v.screenSource === v.getTerminal())
    }
}
