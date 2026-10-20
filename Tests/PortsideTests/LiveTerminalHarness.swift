import Foundation
import XCTest
import SwiftTerm

/// Runs a real program — vim, tmux, a shell — in a pseudo-terminal and feeds
/// what it writes into a real SwiftTerm parser, with no window.
///
/// `TerminalHarness` covers what a byte stream does to the parser. What it
/// can't cover is the conversation: a full-screen program asks the terminal
/// questions (device attributes, cursor position) and draws according to the
/// answers, redraws on SIGWINCH, and switches to the alternate screen and back.
/// Getting any of that wrong doesn't crash anything; the program just draws
/// in the wrong place, which is exactly what a SwiftTerm bump could do without
/// anyone noticing for a week. So here the terminal's replies go back to the
/// program, resizes go through the pty, and assertions are on what the program
/// actually drew.
///
/// Everything touching `Terminal` happens on one serial queue — the process's
/// output is fed on it, and reads hop onto it — because `Terminal` is not
/// thread-safe and the program writes whenever it likes.
final class LiveTerminalHarness {
    private let queue = DispatchQueue(label: "portside.tests.live-terminal")
    private let headless: HeadlessTerminal
    private let exited = ExitBox()

    /// - Parameters:
    ///   - environment: added to a minimal, predictable environment —
    ///     `TERM=xterm-256color`, a UTF-8 locale, and a throwaway `HOME` so a
    ///     user's dotfiles can't change what's drawn.
    init(_ executable: String, _ args: [String] = [], cols: Int = 80, rows: Int = 24,
         environment: [String: String] = [:], directory: String? = nil) {
        var options = TerminalOptions.default
        options.cols = cols
        options.rows = rows
        let box = exited
        headless = HeadlessTerminal(queue: queue, options: options) { code in box.set(code) }
        // A view always knows its cell size; give the headless terminal one
        // too. SwiftTerm 2 sends the in-band size report (mode 2048) only
        // when it has pixel geometry, and neovim, once it sees 2048 is
        // supported, takes its size from that report instead of SIGWINCH.
        let terminal = headless.terminal!
        terminal.terminalLock.withLock { terminal.updatePixelGeometry(cellWidth: 8, cellHeight: 16) }
        var env = [
            "TERM": "xterm-256color",
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "HOME": LiveTerminalHarness.scratchHome,
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
        ]
        env.merge(environment) { $1 }
        // A child inherits its parent thread's signal mask through fork and
        // exec, and async tests run on dispatch worker threads, which block
        // signals. Spawned from one, the program starts with SIGWINCH blocked
        // and never hears about a resize: tmux sat at 80x24 through every
        // resize until this. The app spawns from the main thread, which has
        // nothing blocked, so the child gets the same here.
        var everything = sigset_t(), saved = sigset_t()
        sigemptyset(&everything)
        pthread_sigmask(SIG_SETMASK, &everything, &saved)
        headless.process.startProcess(executable: executable, args: args,
                                      environment: env.map { "\($0.key)=\($0.value)" },
                                      currentDirectory: directory)
        pthread_sigmask(SIG_SETMASK, &saved, nil)
    }

    deinit { stop() }

    static let scratchHome: String = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-live-home-\(UUID().uuidString.prefix(8))").path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// The first of `names` found on the PATH the harness gives programs, so a
    /// test can skip on a machine that hasn't got it rather than fail.
    static func find(_ names: String...) -> String? {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] {
            for name in names where FileManager.default.isExecutableFile(atPath: "\(dir)/\(name)") {
                return "\(dir)/\(name)"
            }
        }
        return nil
    }

    // MARK: Driving

    /// Writes what a user would type. Each write's outcome is kept for the
    /// failure dump: a program that "didn't respond" may never have been sent
    /// anything.
    func send(_ text: String) {
        // Straight to the pty with write(2), not LocalProcess.send: on the
        // macOS 15 CI runner SwiftTerm 2's DispatchIO write channel never
        // completed, so programs never saw a key (#73).
        let fd = headless.process.childfd
        var bytes = Array(text.utf8)[...]
        while !bytes.isEmpty {
            let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n > 0 { bytes = bytes.dropFirst(n); continue }
            if n < 0 && (errno == EAGAIN || errno == EINTR) {
                var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&p, 1, 1000)
                continue
            }
            writes.add("write failed: errno \(errno)")
            return
        }
        writes.add("wrote \(text.utf8.count)")
    }
    private let writes = WriteLog()

    /// Resizes the way a window does: the terminal reflows, then the pty's
    /// size changes, which is what sends the program SIGWINCH.
    func resize(cols: Int, rows: Int) {
        queue.sync {
            headless.terminal.resize(cols: cols, rows: rows)
            var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
            let applied = headless.process.updateWindowSize(&size)
            precondition(applied, "the pty refused the new size")
        }
    }

    func stop() {
        guard exited.code == nil, headless.process.running else { return }
        headless.process.terminate()
    }

    // MARK: Reading

    /// Every row, as `TerminalHarness.line` reads one: wide characters without
    /// their placeholder cell, trailing spaces trimmed. `trimRight` alone only
    /// drops cells nothing was written to, and full-screen programs clear to
    /// the edge by writing spaces.
    var screen: [String] {
        queue.sync {
            let t = headless.terminal!
            return (0..<t.rows).map {
                var row = t.getLine(row: $0)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true) ?? ""
                while row.last == " " { row.removeLast() }
                return row
            }
        }
    }

    /// Every row at full width, one character per column, with cells nothing
    /// was written to read as spaces. `screen` drops those cells, which is
    /// right for text but loses where things are: vttest draws by moving the
    /// cursor over untouched cells, and its tests are about columns.
    var grid: [String] {
        queue.sync {
            let t = headless.terminal!
            return (0..<t.rows).map { row in
                guard let line = t.getLine(row: row) else { return String(repeating: " ", count: t.cols) }
                return String((0..<t.cols).map { col -> Character in
                    let ch = line[col].getCharacter()
                    return ch == "\0" ? " " : ch
                })
            }
        }
    }

    var size: (cols: Int, rows: Int) { queue.sync { (headless.terminal.cols, headless.terminal.rows) } }
    var cursor: (x: Int, y: Int) { queue.sync { (headless.terminal.buffer.x, headless.terminal.buffer.y) } }
    var isAlternateScreen: Bool { queue.sync { headless.terminal.isCurrentBufferAlternate } }
    var exitCode: Int32? { exited.code }
    var cursorStyle: CursorStyle { queue.sync { headless.terminal.options.cursorStyle } }
    var bracketedPasteMode: Bool { queue.sync { headless.terminal.bracketedPasteMode } }
    var mouseMode: Terminal.MouseMode { queue.sync { headless.terminal.mouseMode } }

    /// A left click at a cell (0-based), encoded the way the terminal view
    /// encodes a real one — in whichever protocol the program asked for.
    /// A left click as an SGR mouse report (what `ttymouse=sgr` asks for),
    /// typed rather than generated by `Terminal.sendEvent`: HeadlessTerminal
    /// sends its replies through LocalProcess.send, whose writes stall on
    /// macOS 15 (#73). The app sends replies through PtyWriter instead.
    func click(col: Int, row: Int) {
        send("\u{1b}[<0;\(col + 1);\(row + 1)M\u{1b}[<0;\(col + 1);\(row + 1)m")
    }

    /// The attribute of one cell — colours and style — for a program that
    /// says what it means through them.
    func attribute(col: Int, row: Int) -> Attribute? {
        queue.sync { headless.terminal.getLine(row: row).map { $0[col].attribute } }
    }

    /// Screen text, numbered, for failure messages: an assertion about where
    /// something was drawn is unreadable without seeing what *was* drawn.
    var dump: String {
        screen.enumerated().map { String(format: "%2d|", $0.offset) + $0.element }.joined(separator: "\n")
            + "\nwrites: \(writes.entries.joined(separator: ", "))"
            + "\nrunning: \(headless.process.running)"
    }

    // MARK: Waiting

    /// Waits until `condition` holds for the screen, polling. A program draws
    /// in its own time, so a fixed sleep is either slow or flaky.
    @discardableResult
    func waitFor(_ what: String, timeout: TimeInterval = 15,
                 file: StaticString = #filePath, line: UInt = #line,
                 _ condition: ([String]) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition(screen) { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timed out waiting for \(what)\n\(dump)", file: file, line: line)
        return false
    }

    /// Waits for any row to contain `text`.
    @discardableResult
    func waitFor(text: String, timeout: TimeInterval = 15,
                 file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        await waitFor("\"\(text)\" on screen", timeout: timeout, file: file, line: line) {
            $0.contains { $0.contains(text) }
        }
    }

    @discardableResult
    func waitForExit(timeout: TimeInterval = 15,
                     file: StaticString = #filePath, line: UInt = #line) async -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let code = exited.code { return code }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("process didn't exit\n\(dump)", file: file, line: line)
        return nil
    }

    private final class WriteLog: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        var entries: [String] { lock.lock(); defer { lock.unlock() }; return list }
        func add(_ s: String) { lock.lock(); list.append(s); lock.unlock() }
    }

    private final class ExitBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int32?
        var code: Int32? { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ code: Int32?) { lock.lock(); value = code ?? -1; lock.unlock() }
    }
}
