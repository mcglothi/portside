import XCTest
import SwiftTerm

/// Terminal compatibility suite — large pastes into a real program.
///
/// A paste is one big write into the pty, through the same `LocalProcess.send`
/// the app uses. The program reads it in its own time, so the pty fills and
/// the write has to wait and carry on rather than drop what didn't fit. And a
/// program that turned on bracketed paste gets it wrapped, so an editor treats
/// it as text rather than as thousands of commands.
final class TerminalLivePasteTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        try XCTSkipIf(LiveTerminalHarness.find("vim") == nil, "vim isn't installed")
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-live-paste-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    /// 2 MB, in lines that each say which line they are, so a dropped or
    /// doubled chunk shows up as a mismatch rather than a length difference.
    private let payload: String = (1...20_000).map {
        String(format: "%05d ", $0) + String(repeating: "abcdefghij", count: 9) + "xyz"
    }.joined(separator: "\n") + "\n"

    func testATwoMegabytePasteLandsIntactInVim() async throws {
        let name = "paste.txt"
        let t = LiveTerminalHarness(LiveTerminalHarness.find("vim")!,
                                    ["-u", "NONE", "-i", "NONE", "-N", "-n", "-c", "set nofixeol", name],
                                    environment: ["TERM": "xterm-256color"], directory: dir.path)
        await t.waitFor(text: name)
        await t.waitFor("vim turning on bracketed paste") { _ in t.bracketedPasteMode }

        t.send("\u{1B}[200~" + payload + "\u{1B}[201~")
        // vim stays in normal mode after a bracketed paste; give it time to
        // take in 2 MB, then write.
        await t.waitFor("the last line on screen", timeout: 120) { $0.contains { $0.hasPrefix("20000 ") } }
        t.send(":wq\r")
        let code = await t.waitForExit(timeout: 60)
        XCTAssertEqual(code, 0)

        // vim keeps the empty line the buffer started with after the pasted
        // text, so the file has one more newline at the end; that's vim, not
        // the terminal. Every pasted line has to be there, in order.
        let written = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            .trimmingCharacters(in: .newlines) + "\n"
        XCTAssertEqual(written.utf8.count, payload.utf8.count, "byte count")
        let firstDifference = Array(zip(written.split(separator: "\n"), payload.split(separator: "\n")))
            .firstIndex { $0.0 != $0.1 }
        XCTAssertTrue(written == payload, "contents differ — first at line \((firstDifference ?? -1) + 1)")
    }
}
