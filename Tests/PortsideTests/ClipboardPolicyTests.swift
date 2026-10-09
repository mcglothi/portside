import XCTest
import AppKit
import SwiftTerm
@testable import Portside

/// OSC 52 through Portside's real terminal view: what a remote program can
/// do to — and learn from — the clipboard. Each test has a private pasteboard
/// for copies, so it can't race another test or touch the user's clipboard.
/// Reads are refused before any pasteboard is consulted; that test puts a
/// secret on the system clipboard (and restores what was there).
@MainActor
final class ClipboardPolicyTests: XCTestCase {
    private var saved: String?
    private let board = NSPasteboard(name: NSPasteboard.Name("portside-test-\(UUID().uuidString)"))

    override func setUp() async throws {
        saved = NSPasteboard.general.string(forType: .string)
    }

    override func tearDown() async throws {
        board.releaseGlobally()
    }

    private func view() -> (LoggingTerminalView, () -> String) {
        let view = LoggingTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.useClipboard(board)
        var sent: [UInt8] = []
        view.transportWriter = { sent += $0 }
        return (view, { String(decoding: sent, as: UTF8.self) })
    }

    /// A program asking what's on the clipboard gets no answer — nothing is
    /// typed back to it at all.
    func testARemoteProgramCantReadTheClipboard() {
        let secret = "hunter2-\(UUID().uuidString.prefix(6))"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(secret, forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let saved { NSPasteboard.general.setString(saved, forType: .string) }
        }
        let (view, sent) = view()

        view.feed(byteArray: Array("\u{1B}]52;c;?\u{07}".utf8)[...])
        view.feed(byteArray: Array("\u{1B}]52;c;?\u{1B}\\".utf8)[...])

        XCTAssertFalse(sent().contains("52;"), "the terminal answered a clipboard query: \(sent().debugDescription)")
        XCTAssertFalse(sent().contains(Data(secret.utf8).base64EncodedString()))
    }

    /// Copying from tmux or an editor over ssh still reaches the clipboard.
    func testARemoteProgramCanStillCopyToTheClipboard() {
        let (view, _) = view()
        let text = "copied-\(UUID().uuidString.prefix(6))"
        view.feed(byteArray: Array("\u{1B}]52;c;\(Data(text.utf8).base64EncodedString())\u{07}".utf8)[...])
        XCTAssertEqual(board.string(forType: .string), text)
    }

    func testAnOversizedCopyIsIgnored() {
        board.clearContents()
        board.setString("before", forType: .string)
        let (view, _) = view()
        let huge = Data(repeating: 0x41, count: (1 << 20) + 1).base64EncodedString()
        view.feed(byteArray: Array("\u{1B}]52;c;\(huge)\u{07}".utf8)[...])
        XCTAssertEqual(board.string(forType: .string), "before")
    }

    /// The stand-in delegate passes everything else through: a terminal
    /// query (device attributes) is still answered.
    func testOtherRepliesStillReachTheProgram() {
        let (view, sent) = view()
        view.feed(byteArray: Array("\u{1B}[c".utf8)[...])
        XCTAssertTrue(sent().hasPrefix("\u{1B}[?"), sent().debugDescription)
    }
}
