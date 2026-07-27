import AppKit
import Foundation
import XCTest
@testable import Portside

/// Locks the routing contract in `LoggingTerminalView.dataReceived`: the log and
/// the command timeline see the bytes as they arrived, and only the terminal
/// sees the stream `SixelStreamGuard` repaired.
///
/// The ordering is a contract rather than an implementation detail — moving the
/// filter a few lines up would feed repaired bytes to the transcript, and the
/// guard changes the byte count. Raised by Codex CLI in the 0.17 pre-release
/// review, which noted the guard was tested directly but this wiring was not.
@MainActor
final class TerminalRoutingTests: XCTestCase {

    /// A single-band sixel with no trailing terminator: the guard appends `-`,
    /// so raw and repaired differ by exactly one byte.
    private let unterminatedSixel = "\u{1b}Pq#0;2;100;100;100#0~~\u{1b}\\"

    private func makeView() -> LoggingTerminalView {
        LoggingTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    }

    func testTerminalReceivesTheRepairedStream() {
        let view = makeView()
        var handedToTerminal: [UInt8] = []
        view.onTerminalBytes = { handedToTerminal = Array($0) }

        let raw = [UInt8](unterminatedSixel.utf8)
        view.dataReceived(slice: raw[...])

        XCTAssertEqual(
            String(decoding: handedToTerminal, as: UTF8.self),
            "\u{1b}Pq#0;2;100;100;100#0~~-\u{1b}\\",
            "the terminal must get the repaired stream, or it crashes on this vector"
        )
        XCTAssertEqual(handedToTerminal.count, raw.count + 1)
    }

    /// Ordinary output must reach the terminal untouched — the guard is a repair
    /// for one defect, not a filter on everything.
    func testOrdinaryOutputReachesTheTerminalUnchanged() {
        let view = makeView()
        var handedToTerminal: [UInt8] = []
        view.onTerminalBytes = { handedToTerminal = Array($0) }

        let raw = [UInt8]("hello\r\n\u{1b}[31mred\u{1b}[0m\r\n".utf8)
        view.dataReceived(slice: raw[...])

        XCTAssertEqual(handedToTerminal, raw)
    }

    /// The transcript must not see the repair.
    ///
    /// **This one cannot fail, and that is the finding.** The review asked for
    /// it on the grounds that feeding repaired bytes to the logger would
    /// silently invalidate persisted transcript offsets. Measured rather than
    /// assumed: rewriting `dataReceived` to hand `logger?.append` the *repaired*
    /// slice leaves this test green, because every byte the guard inserts lands
    /// inside a DCS body and `ANSIStripper` has a `dcs` state that drops DCS
    /// bodies wholesale. Transcript content and `settledOffset()` come out
    /// identical either way, so the offset corruption is unreachable through
    /// this guard.
    ///
    /// Kept as a shape guard — a future repair that inserts outside a DCS would
    /// diverge here — but the assertion carrying the weight is
    /// `testTerminalReceivesTheRepairedStream` above, which does fail when the
    /// terminal stops receiving repaired bytes.
    func testTranscriptMatchesARawFedControl() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-routing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let raw = [UInt8]((unterminatedSixel + "after\r\n").utf8)

        let viaView = try XCTUnwrap(SessionLogger(
            fileURL: dir.appendingPathComponent("view.log"), title: "t", subtitle: ""))
        let view = makeView()
        view.logger = viaView
        view.dataReceived(slice: raw[...])

        let control = try XCTUnwrap(SessionLogger(
            fileURL: dir.appendingPathComponent("control.log"), title: "t", subtitle: ""))
        control.append(raw[...])

        // Both loggers write asynchronously on their own queue.
        _ = viaView.settledOffset()
        _ = control.settledOffset()

        let viaViewText = try String(contentsOf: viaView.fileURL, encoding: .utf8)
        let controlText = try String(contentsOf: control.fileURL, encoding: .utf8)

        // Headers carry timestamps, so compare only what was appended after them.
        XCTAssertEqual(body(of: viaViewText), body(of: controlText))
        XCTAssertTrue(viaViewText.contains("after"), "plain output should still reach the transcript")
    }

    private func body(of log: String) -> String {
        guard let range = log.range(of: "════\n\n", options: .backwards) else {
            return log.split(separator: "\n").last.map(String.init) ?? log
        }
        return String(log[range.upperBound...])
    }
}
