import Foundation
import SwiftTerm

/// Drives a real SwiftTerm parser with no window, so the compatibility suite
/// can assert on what the terminal *became* rather than on what it drew.
///
/// The point of the suite (see `docs/road-to-1.0.md`) is to stand between a
/// SwiftTerm bump and a regression nobody notices for a week. That means it has
/// to be fast and deterministic enough to run on every build, which rules out
/// screenshots and rules out driving the app. `Terminal` is separable from
/// `TerminalView`: it parses bytes into a buffer, and the buffer is readable.
/// Everything that has actually bitten this project — a Sixel crash, a
/// transcript swallowed by an unterminated sequence — lives on that side.
///
/// What this deliberately cannot cover is rendering: font metrics, glyph
/// shaping, colour on screen. Those need the view and a window, and are checked
/// by looking at the app.
final class TerminalHarness {
    let terminal: Terminal
    private let sink = Sink()

    init(cols: Int = 80, rows: Int = 24) {
        var options = TerminalOptions.default
        options.cols = cols
        options.rows = rows
        terminal = Terminal(delegate: sink, options: options)
    }

    // MARK: Feeding

    func feed(_ bytes: [UInt8]) { terminal.feed(byteArray: bytes) }
    func feed(_ text: String) { terminal.feed(text: text) }

    /// Feeds the same bytes split into fixed-size chunks.
    ///
    /// This is the shape a pty actually delivers: `read()` returns whatever
    /// happens to be available, so an escape sequence can be split at any byte.
    /// A parser that only works on whole sequences looks perfectly fine until
    /// it meets a slow link.
    func feed(_ bytes: [UInt8], inChunksOf size: Int) {
        var index = 0
        while index < bytes.count {
            let end = min(index + size, bytes.count)
            terminal.feed(byteArray: Array(bytes[index..<end]))
            index = end
        }
    }

    // MARK: Reading

    /// One row as text.
    ///
    /// `skipNullCellsFollowingWide` is not optional here. A double-width
    /// character occupies two cells — the glyph, then a null placeholder — and
    /// without this the placeholder reads as a space, so "日本語" comes back as
    /// "日 本 語". Every CJK and emoji assertion in the suite would have been
    /// written against that padding and passed while meaning nothing.
    func line(_ row: Int) -> String {
        terminal.getLine(row: row)?
            .translateToString(trimRight: true, skipNullCellsFollowingWide: true) ?? ""
    }

    /// Every row, trailing blank rows trimmed — the readable form of "what is
    /// on screen", which is what an assertion should be written against.
    var screen: [String] {
        var rows = (0..<terminal.rows).map { line($0) }
        while rows.last?.isEmpty == true { rows.removeLast() }
        return rows
    }

    var cursor: (x: Int, y: Int) { (terminal.buffer.x, terminal.buffer.y) }

    /// Titles the stream asked for, in order — OSC 0/2 and friends.
    var titles: [String] { sink.titles }
    /// Directories reported through OSC 7, which the SFTP pane follows.
    var reportedDirectory: String? { terminal.hostCurrentDirectory }
    /// Bytes the terminal wrote back to the host (device reports, and so on).
    var replies: [UInt8] { sink.replies }
    var bells: Int { sink.bells }

    // MARK: -

    /// Records the delegate callbacks worth asserting on and ignores the rest.
    /// Every method is required by the protocol; most are no-ops here on
    /// purpose, so a new one appearing in a SwiftTerm bump shows up as a
    /// compile error rather than as silence.
    private final class Sink: TerminalDelegate {
        var titles: [String] = []
        var replies: [UInt8] = []
        var bells = 0

        func setTerminalTitle(source: Terminal, title: String) { titles.append(title) }
        func send(source: Terminal, data: ArraySlice<UInt8>) { replies.append(contentsOf: data) }
        func bell(source: Terminal) { bells += 1 }

        func showCursor(source: Terminal) {}
        func hideCursor(source: Terminal) {}
        func setTerminalIconTitle(source: Terminal, title: String) {}
        func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? { nil }
        func sizeChanged(source: Terminal) {}
        func scrolled(source: Terminal, yDisp: Int) {}
        func linefeed(source: Terminal) {}
        func bufferActivated(source: Terminal) {}
        func synchronizedOutputChanged(source: Terminal, active: Bool) {}
        func selectionChanged(source: Terminal) {}
        func isProcessTrusted(source: Terminal) -> Bool { true }
        func cellSizeInPixels(source: Terminal) -> (width: Int, height: Int)? { (8, 16) }
        func mouseModeChanged(source: Terminal) {}
        func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) {}
        func hostCurrentDirectoryUpdated(source: Terminal) {}
        func hostCurrentDocumentUpdated(source: Terminal) {}
        func colorChanged(source: Terminal, idx: Int?) {}
        func setForegroundColor(source: Terminal, color: Color) {}
        func setBackgroundColor(source: Terminal, color: Color) {}
        func setCursorColor(source: Terminal, color: Color?) {}
        func getColors(source: Terminal) -> (foreground: Color, background: Color) {
            (Color(red: 0, green: 0, blue: 0), Color(red: 65535, green: 65535, blue: 65535))
        }
        func iTermContent(source: Terminal, content: ArraySlice<UInt8>) {}
        func clipboardCopy(source: Terminal, content: Data) {}
        func clipboardRead(source: Terminal) -> Data? { nil }
        func notify(source: Terminal, title: String, body: String) {}
        func progressReport(source: Terminal, report: Terminal.ProgressReport) {}
        func createImageFromBitmap(source: Terminal, bytes: inout [UInt8], width: Int, height: Int) {}
        func createImage(source: Terminal, data: Data, width: ImageSizeRequest,
                         height: ImageSizeRequest, preserveAspectRatio: Bool) {}
    }
}
