import XCTest
import SwiftTerm

/// Terminal compatibility suite — neovim, running for real.
///
/// neovim leans on more of the terminal than vim does by default: it draws
/// with 24-bit colour when the terminal says it can, changes the cursor's
/// shape between modes (DECSCUSR), and turns on bracketed paste. Each of those
/// fails quietly when the terminal gets it wrong — a palette that's almost
/// right, a block cursor in insert mode, a paste that runs as keystrokes.
///
/// `--clean` runs it with no config or plugins, and `-n` with no swap file.
final class TerminalLiveNeovimTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        try XCTSkipIf(LiveTerminalHarness.find("nvim") == nil, "neovim isn't installed")
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-live-nvim-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func file(_ name: String, _ contents: String) throws -> String {
        try contents.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        return name
    }

    private func nvim(_ name: String, _ extra: [String] = [], cols: Int = 80, rows: Int = 24) -> LiveTerminalHarness {
        LiveTerminalHarness(LiveTerminalHarness.find("nvim")!,
                            ["--clean", "-n", "-c", "set laststatus=2 noshowmode"] + extra + [name],
                            cols: cols, rows: rows, environment: ["COLORTERM": "truecolor"],
                            directory: dir.path)
    }

    func testNeovimDrawsTheFileAndItsStatusLine() async throws {
        let t = nvim(try file("notes.txt", "alpha\nbeta\n"))
        await t.waitFor("the status line on row 22") { $0[22].contains("notes.txt") }
        XCTAssertEqual(Array(t.screen.prefix(2)), ["alpha", "beta"], t.dump)
        XCTAssertTrue(t.isAlternateScreen)
        t.send(":q\r")
        await t.waitForExit()
    }

    func testQuittingNeovimPutsTheShellScreenBack() async throws {
        let path = try file("a.txt", "inside-nvim\n")
        let nvimPath = LiveTerminalHarness.find("nvim")!
        let t = LiveTerminalHarness("/bin/sh", ["-c",
            "echo before-nvim; '\(nvimPath)' --clean -n '\(path)'; echo after-nvim $?; sleep 30"],
            directory: dir.path)
        await t.waitFor(text: "inside-nvim")
        t.send(":q\r")
        await t.waitFor(text: "after-nvim 0")
        XCTAssertFalse(t.isAlternateScreen)
        XCTAssertTrue(t.screen.contains("before-nvim"), t.dump)
        XCTAssertFalse(t.screen.contains { $0.contains("inside-nvim") }, t.dump)
    }

    func testNeovimRedrawsToANewSize() async throws {
        let t = nvim(try file("resize.txt", "line\n"))
        await t.waitFor("the status line") { $0[22].contains("resize.txt") }
        t.resize(cols: 100, rows: 30)
        await t.waitFor("the status line on row 28") { $0.count == 30 && $0[28].contains("resize.txt") }
        t.send(":echo &columns . 'x' . &lines\r")
        await t.waitFor("neovim reporting 100x30") { $0[29].contains("100x30") }
        t.resize(cols: 50, rows: 12)
        await t.waitFor("the status line on row 10") { $0.count == 12 && $0[10].contains("resize.txt") }
        t.send(":q\r")
        await t.waitForExit()
    }

    func testNeovimAndTheTerminalAgreeOnWideCharacterColumns() async throws {
        let t = nvim(try file("wide.txt", "日本語|\nabcdef|\n"))
        await t.waitFor(text: "日本語|")
        t.send("gg$")
        await t.waitFor("the cursor on the first bar") { _ in t.cursor == (6, 0) }
        t.send("j$")
        await t.waitFor("the cursor on the second bar") { _ in t.cursor == (6, 1) }
        t.send(":q\r")
        await t.waitForExit()
    }

    /// With `termguicolors`, a highlight is sent as a 24-bit colour, and the
    /// cell holds that exact colour — not the nearest of 256.
    func testTrueColourArrivesExactly() async throws {
        let t = nvim(try file("colour.txt", "painted\n"),
                     ["-c", "set termguicolors", "-c", "hi Normal guifg=#c0ffee guibg=#123456"])
        await t.waitFor(text: "painted")
        await t.waitFor("the 24-bit background") { _ in
            t.attribute(col: 0, row: 0)?.bg == .trueColor(red: 0x12, green: 0x34, blue: 0x56)
        }
        XCTAssertEqual(t.attribute(col: 0, row: 0)?.fg, .trueColor(red: 0xc0, green: 0xff, blue: 0xee))
        t.send(":q\r")
        await t.waitForExit()
    }

    /// The cursor's shape follows the mode: a bar in insert mode, a block
    /// back in normal mode. A terminal that ignores DECSCUSR leaves a block
    /// cursor while you type, and you can't see which mode you're in.
    func testTheCursorShapeFollowsTheMode() async throws {
        let t = nvim(try file("shape.txt", "x\n"))
        await t.waitFor(text: "shape.txt")
        t.send("i")
        await t.waitFor("a bar cursor in insert mode") { _ in
            [.steadyBar, .blinkBar].contains(t.cursorStyle)
        }
        t.send("\u{1B}")
        await t.waitFor("a block cursor in normal mode") { _ in
            [.steadyBlock, .blinkBlock].contains(t.cursorStyle)
        }
        t.send(":q!\r")
        await t.waitForExit()
    }
}
