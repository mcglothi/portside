import XCTest
import SwiftTerm

/// Terminal compatibility suite — `less`, running for real.
///
/// `less` is what every `man`, `git log` and `journalctl` lands in: it pages
/// by redrawing, scrolls back a line at a time (reverse index or an insert-
/// line), and marks search matches in reverse video. `top` is a curses
/// program that redraws on a timer and re-lays out on SIGWINCH. Both run with
/// a scratch HOME and no options from the environment, so a user's `LESS` or
/// `.toprc` can't change what's drawn.
final class TerminalLivePagerTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-live-pager-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (1...200).map { String(format: "line %03d of the file", $0) }.joined(separator: "\n")
            .appending("\n").write(to: dir.appendingPathComponent("numbers.txt"), atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func less() -> LiveTerminalHarness {
        LiveTerminalHarness("/usr/bin/less", ["numbers.txt"],
                            environment: ["LESS": "", "LESSHISTFILE": "-", "LESSKEY": "/dev/null"],
                            directory: dir.path)
    }

    func testLessPagesForwardBackAndToTheEnd() async {
        let t = less()
        await t.waitFor("the first page") { $0[0] == "line 001 of the file" }
        XCTAssertEqual(t.screen[22], "line 023 of the file", t.dump)

        t.send(" ")
        await t.waitFor("the second page") { $0[0] == "line 024 of the file" }
        t.send("b")
        await t.waitFor("back to the first") { $0[0] == "line 001 of the file" }
        t.send("G")
        await t.waitFor("the end") { $0.contains { $0.hasPrefix("line 200") } && $0.contains { $0.contains("(END)") } }
        t.send("q")
        await t.waitForExit()
    }

    /// One line back is drawn by scrolling the screen *down* — reverse index
    /// or an insert-line — not by repainting the page. Get that wrong and the
    /// page tears or repeats a line.
    func testLessScrollsBackALineAtATime() async {
        let t = less()
        await t.waitFor("the first page") { $0[0] == "line 001 of the file" }
        t.send(" ")
        await t.waitFor("the second page") { $0[0] == "line 024 of the file" }
        t.send("k")
        await t.waitFor("one line back") { $0[0] == "line 023 of the file" }
        let s = t.screen
        for row in 0..<23 { XCTAssertEqual(s[row], String(format: "line %03d of the file", 23 + row), t.dump) }
        t.send("q")
        await t.waitForExit()
    }

    /// A match is shown in reverse video, on the row less put it on.
    func testLessHighlightsASearchMatch() async {
        let t = less()
        await t.waitFor("the first page") { $0[0] == "line 001 of the file" }
        t.send("/line 150\r")
        await t.waitFor("the match on screen") { $0.contains { $0.hasPrefix("line 150") } }
        guard let row = t.screen.firstIndex(where: { $0.hasPrefix("line 150") }) else {
            return XCTFail("no match on screen\n\(t.dump)")
        }
        XCTAssertTrue(t.attribute(col: 0, row: row)?.style.contains(.inverse) == true,
                      "the match isn't highlighted\n\(t.dump)")
        XCTAssertFalse(t.attribute(col: 10, row: row)?.style.contains(.inverse) == true, "only the match")
        t.send("q")
        await t.waitForExit()
    }

    func testQuittingLessPutsTheShellScreenBack() async {
        let t = LiveTerminalHarness("/bin/sh", ["-c", "echo before-less; /usr/bin/less numbers.txt; echo after-less $?; sleep 30"],
                                    environment: ["LESS": "", "LESSHISTFILE": "-"], directory: dir.path)
        await t.waitFor("less") { $0[0] == "line 001 of the file" }
        t.send("q")
        await t.waitFor(text: "after-less 0")
        XCTAssertTrue(t.screen.contains("before-less"), t.dump)
        XCTAssertFalse(t.screen.contains { $0.hasPrefix("line 0") }, t.dump)
    }
}
