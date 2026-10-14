import Foundation
import SwiftTerm

/// A second, headless terminal fed the same bytes as a session's view, so
/// agents can read the screen and its scrollback from Portside's own copy.
///
/// SwiftTerm v2 keeps the view's terminal to itself: it exposes the visible
/// rows, not scrollback, and `getTerminal()` is gone (#69). Agent `screen`
/// returns up to 500 lines including what scrolled off, so it needs a buffer
/// Portside owns. The bytes are the ones the view gets, after
/// `TerminalImageGuard`, so both parse the same thing.
///
/// Only kept while agents may read sessions (the same switch as command
/// capture): it holds a second copy of the scrollback.
final class ShadowScreen {
    let terminal: Terminal
    /// Whether it has seen everything the session printed. One switched on
    /// mid-session lacks what came before, and isn't used for reads then.
    let complete: Bool
    private let sink = QuietDelegate()

    init(cols: Int, rows: Int, scrollback: Int, complete: Bool) {
        var options = TerminalOptions.default
        options.cols = max(cols, 1)
        options.rows = max(rows, 1)
        options.scrollback = scrollback
        terminal = Terminal(delegate: sink, options: options)
        self.complete = complete
    }

    func feed(_ bytes: ArraySlice<UInt8>) {
        terminal.feed(byteArray: Array(bytes))
    }

    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0, cols != terminal.cols || rows != terminal.rows else { return }
        terminal.resize(cols: cols, rows: rows)
    }

    func changeScrollback(_ lines: Int) {
        terminal.changeScrollback(lines)
    }
}

/// The shadow's delegate. Above all it must not answer the host: the view
/// already replies to queries (device attributes, cursor position), and a
/// second answer would reach the remote program as typed input.
private final class QuietDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}
