import XCTest
import SwiftTerm

/// Terminal compatibility suite — vim, running for real.
///
/// vim is the full-screen program everyone opens over ssh, and the one that
/// leans hardest on the terminal agreeing with it: it switches to the
/// alternate screen and expects the shell's screen back on exit, positions
/// every redraw absolutely, asks the pty for its size on SIGWINCH, and counts
/// display columns itself. A disagreement on any of these doesn't fail
/// loudly — the status line lands on the wrong row, or the cursor sits a
/// column to the left of where you're typing.
///
/// vim runs with no vimrc, viminfo or swap file (`-u NONE -i NONE -n`), so a
/// machine's own configuration can't change what is drawn.
final class TerminalLiveVimTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        try XCTSkipIf(LiveTerminalHarness.find("vim") == nil, "vim isn't installed")
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-live-vim-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    /// Writes a file into the test's directory and returns its name. vim runs
    /// in that directory, so the status line shows the short name rather than
    /// a temp path long enough to be truncated.
    private func file(_ name: String, _ contents: String) throws -> String {
        try contents.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        return name
    }

    private func vim(_ name: String, cols: Int = 80, rows: Int = 24) -> LiveTerminalHarness {
        LiveTerminalHarness(LiveTerminalHarness.find("vim")!,
                            ["-u", "NONE", "-i", "NONE", "-N", "-n", "-c", "set laststatus=2", name],
                            cols: cols, rows: rows, directory: dir.path)
    }

    func testVimDrawsTheFileAndPutsItsStatusLineOnTheLastRows() async throws {
        let path = try file("notes.txt", "alpha\nbeta\n")
        let t = vim(path)
        await t.waitFor(text: "notes.txt")

        let s = t.screen
        XCTAssertEqual(Array(s.prefix(3)), ["alpha", "beta", "~"], t.dump)
        // laststatus=2: the status line is the second-to-last row, the command
        // line the last. Drawn in the wrong place means vim and the terminal
        // disagree about how tall the screen is.
        XCTAssertTrue(s[22].contains("notes.txt"), t.dump)
        XCTAssertTrue(t.isAlternateScreen, "vim draws on the alternate screen")
        t.send(":q\r")
        await t.waitForExit()
    }

    /// The shell's screen comes back when vim exits. A terminal without a
    /// working alternate screen leaves vim's last frame over your scrollback.
    func testQuittingVimPutsTheShellScreenBack() async throws {
        let path = try file("a.txt", "inside-vim\n")
        let vimPath = LiveTerminalHarness.find("vim")!
        let t = LiveTerminalHarness("/bin/sh", ["-c",
            "echo before-vim; '\(vimPath)' -u NONE -i NONE -N -n '\(path)'; echo after-vim $?; sleep 30"],
            directory: dir.path)
        await t.waitFor(text: "inside-vim")
        XCTAssertFalse(t.screen.contains { $0.contains("before-vim") }, "vim's screen replaced the shell's")

        t.send(":q\r")
        await t.waitFor(text: "after-vim 0")
        XCTAssertFalse(t.isAlternateScreen)
        XCTAssertTrue(t.screen.contains("before-vim"), "the shell's output is still there\n\(t.dump)")
        XCTAssertFalse(t.screen.contains { $0.contains("inside-vim") }, "vim's frame is gone\n\(t.dump)")
    }

    /// A window resize reaches vim as SIGWINCH plus a new pty size, and vim
    /// redraws to it. Asked afterwards, vim reports the new size itself.
    func testVimRedrawsToANewSize() async throws {
        let path = try file("resize.txt", "line\n")
        let t = vim(path)
        await t.waitFor(text: "resize.txt")

        t.resize(cols: 100, rows: 30)
        await t.waitFor("the status line on row 28") { $0.count == 30 && $0[28].contains("resize.txt") }
        // One at a time: asking for both makes vim stop at "Press ENTER".
        t.send(":set columns?\r")
        await t.waitFor("vim reporting columns=100") { $0[29].contains("columns=100") }
        t.send(":set lines?\r")
        await t.waitFor("vim reporting lines=30") { $0[29].contains("lines=30") }

        // Smaller, too: shrinking is where a stale size draws off the edge.
        t.resize(cols: 50, rows: 12)
        await t.waitFor("the status line on row 10") { $0.count == 12 && $0[10].contains("resize.txt") }
        t.send(":q\r")
        await t.waitForExit()
    }

    /// vim wraps a long line itself and draws the continuation on the next
    /// row; the terminal must not wrap it a second time or leave a gap.
    func testALongLineWrapsOntoExactlyTheRowsVimExpects() async throws {
        let long = String(repeating: "x", count: 150) + "END"
        let path = try file("long.txt", long + "\nnext\n")
        let t = vim(path)
        await t.waitFor(text: "long.txt")

        let s = t.screen
        XCTAssertEqual(s[0], String(repeating: "x", count: 80), t.dump)
        XCTAssertEqual(s[1], String(repeating: "x", count: 70) + "END", t.dump)
        XCTAssertEqual(s[2], "next", t.dump)
        t.send(":q\r")
        await t.waitForExit()
    }

    /// vim counts display columns on its side; the terminal counts them on
    /// its own. With CJK on a line they have to agree, or the cursor is drawn
    /// left of the character it's on and every edit lands in the wrong place.
    func testVimAndTheTerminalAgreeOnWideCharacterColumns() async throws {
        let path = try file("wide.txt", "日本語|\nabcdef|\n")
        let t = vim(path)
        await t.waitFor(text: "wide.txt")
        XCTAssertEqual(t.screen[0], "日本語|", t.dump)

        // `$` puts vim's cursor on the bar; where the terminal's cursor ends
        // up is where vim believes that column is.
        t.send("gg$")
        await t.waitFor("the cursor on the first bar") { _ in t.cursor == (6, 0) }
        t.send("j$")
        await t.waitFor("the cursor on the second bar") { _ in t.cursor == (6, 1) }
        t.send(":q\r")
        await t.waitForExit()
    }

    /// Keystrokes go in through the pty and come out as a file — the input
    /// half of the same path, including Escape arriving on its own.
    func testTypingInsertsAndWritesTheFile() async throws {
        let path = try file("typed.txt", "")
        let t = vim(path)
        await t.waitFor(text: "typed.txt")

        t.send("ihello from portside\u{1B}")
        await t.waitFor(text: "hello from portside")
        t.send(":wq\r")
        let code = await t.waitForExit()
        XCTAssertEqual(code, 0)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent(path), encoding: .utf8),
                       "hello from portside\n")
    }
}
