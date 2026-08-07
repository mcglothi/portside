import AppKit
import Foundation
import XCTest
@testable import Portside

/// Locks the routing contract in `LoggingTerminalView.dataReceived`: the log,
/// the command timeline and the terminal all see the bytes as they arrived.
///
/// The ordering is a contract rather than an implementation detail. Until
/// 0.22.4 a `SixelStreamGuard` sat in this path repairing unterminated sixel
/// payloads, and the risk these tests were written for (Codex CLI, 0.17
/// pre-release review) was that a repaired stream would reach `logger?.append`
/// and silently invalidate persisted transcript offsets. SwiftTerm 1.16.0 fixed
/// the decoder crash and the guard is gone, but the contract it was tested
/// against outlives it — anything reinserted here must not rewrite the bytes
/// the transcript records.
@MainActor
final class TerminalRoutingTests: XCTestCase {

    /// A single-band sixel with no trailing terminator — the vector that used to
    /// crash SwiftTerm's decoder, now handled upstream. Kept as the sample
    /// because it is the one that must pass through untouched.
    private let unterminatedSixel = "\u{1b}Pq#0;2;100;100;100#0~~\u{1b}\\"

    private func makeView() -> LoggingTerminalView {
        LoggingTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    }

    func testSixelReachesTheTerminalUnchanged() {
        let view = makeView()
        var handedToTerminal: [UInt8] = []
        view.onTerminalBytes = { handedToTerminal = Array($0) }

        let raw = [UInt8](unterminatedSixel.utf8)
        view.dataReceived(slice: raw[...])

        XCTAssertEqual(
            handedToTerminal, raw,
            "sixel is the terminal's to parse; nothing in this path may rewrite it")
    }

    /// Ordinary output must reach the terminal untouched too — this path is
    /// a tap for the log and the timeline, not a filter.
    func testOrdinaryOutputReachesTheTerminalUnchanged() {
        let view = makeView()
        var handedToTerminal: [UInt8] = []
        view.onTerminalBytes = { handedToTerminal = Array($0) }

        let raw = [UInt8]("hello\r\n\u{1b}[31mred\u{1b}[0m\r\n".utf8)
        view.dataReceived(slice: raw[...])

        XCTAssertEqual(handedToTerminal, raw)
    }

    /// The transcript must match what a logger fed the same bytes directly
    /// produces — the assertion that would catch a future filter in this path
    /// shifting the offsets `CommandEvent.logOffset` persists.
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
