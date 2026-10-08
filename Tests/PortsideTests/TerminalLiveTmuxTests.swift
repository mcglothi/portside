import XCTest
import SwiftTerm

/// Terminal compatibility suite — tmux, running for real.
///
/// tmux is a terminal inside the terminal: it redraws the whole screen from
/// its own model, so any disagreement with ours shows up at once and stays.
/// It's also where line drawing comes from on a server — pane borders are
/// drawn with box characters in UTF-8, or with the DEC special graphics set
/// when the locale isn't UTF-8 — and it relies on SIGWINCH to re-lay every
/// pane after a window resize.
///
/// Each test runs its own tmux server on a private socket with no config file,
/// so neither a user's `~/.tmux.conf` nor a running tmux can change anything.
final class TerminalLiveTmuxTests: XCTestCase {
    private var tmux: String!
    private var socket: String!

    override func setUpWithError() throws {
        tmux = LiveTerminalHarness.find("tmux")
        try XCTSkipIf(tmux == nil, "tmux isn't installed")
        socket = "portside-test-\(UUID().uuidString.prefix(8))"
    }

    override func tearDown() {
        guard let tmux, let socket else { return }
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: tmux)
        kill.arguments = ["-L", socket, "kill-server"]
        kill.standardError = FileHandle.nullDevice
        try? kill.run()
        kill.waitUntilExit()
    }

    private var tmuxArgs: [String] { ["-L", socket, "-f", "/dev/null", "new-session", "-s", "live"] }

    private func start(cols: Int = 80, rows: Int = 24, locale: String = "en_US.UTF-8") -> LiveTerminalHarness {
        LiveTerminalHarness(tmux, tmuxArgs, cols: cols, rows: rows,
                            environment: ["SHELL": "/bin/sh", "LANG": locale, "LC_ALL": locale])
    }

    func testTmuxDrawsItsStatusBarOnTheLastRow() async {
        let t = start()
        await t.waitFor("the status bar on row 23") { $0[23].contains("[live]") }
        await t.waitFor("the shell prompt in the pane") { $0[0].hasSuffix("$") }
        XCTAssertTrue(t.isAlternateScreen, "tmux draws on the alternate screen")
    }

    /// Pane borders in UTF-8 are box-drawing characters written as-is.
    func testASplitDrawsItsBorderInUTF8() async {
        let t = start()
        await t.waitFor("the status bar") { $0[23].contains("[live]") }
        t.send("\u{02}\"") // prefix, then split top/bottom
        await t.waitFor("a horizontal border") { $0.contains { $0.contains(String(repeating: "─", count: 40)) } }
    }

    /// Without a UTF-8 locale tmux draws the same border with the DEC special
    /// graphics set: it switches character set and writes `q`. A terminal that
    /// doesn't map it shows a row of q's where the border should be — the
    /// classic look of a broken terminal over ssh to an old box.
    func testASplitDrawsItsBorderWithDECLineDrawing() async {
        let t = start(locale: "C")
        await t.waitFor("the status bar") { $0[23].contains("[live]") }
        t.send("\u{02}\"")
        await t.waitFor("a horizontal border") { $0.contains { $0.contains(String(repeating: "─", count: 40)) } }
        XCTAssertFalse(t.screen.contains { $0.contains("qqqqqqqqqq") }, "no raw q's\n\(t.dump)")
    }

    /// A resize reaches tmux, tmux re-lays out, and the shell inside the pane
    /// is told the pane's new size in turn — two levels of SIGWINCH.
    func testTmuxAndThePaneFollowAResize() async {
        let t = start()
        await t.waitFor("the shell prompt") { $0[0].hasSuffix("$") }

        t.resize(cols: 120, rows: 40)
        await t.waitFor("the status bar on row 39") { $0.count == 40 && $0[39].contains("[live]") }
        t.send("stty size\r")
        // One row less than the window: the status bar has the last one.
        await t.waitFor(text: "39 120")
    }

    /// Leaving tmux puts back what was on screen before it.
    func testExitingTmuxPutsTheShellScreenBack() async {
        let line = ([tmux!] + tmuxArgs).map { "'\($0)'" }.joined(separator: " ")
        let t = LiveTerminalHarness("/bin/sh", ["-c", "echo before-tmux; \(line); echo after-tmux $?; sleep 30"],
                                    environment: ["SHELL": "/bin/sh"])
        await t.waitFor("tmux's status bar") { $0[23].contains("[live]") }
        XCTAssertFalse(t.screen.contains("before-tmux"), "tmux's screen replaced the shell's")

        t.send("exit\r")
        await t.waitFor(text: "after-tmux 0")
        XCTAssertFalse(t.isAlternateScreen)
        XCTAssertTrue(t.screen.contains("before-tmux"), t.dump)
        XCTAssertFalse(t.screen.contains { $0.contains("[live]") }, "tmux's status bar is gone\n\(t.dump)")
    }
}
