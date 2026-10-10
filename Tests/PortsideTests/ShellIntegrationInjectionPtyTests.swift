import XCTest
@testable import Portside

/// The injection as it actually travels: typed into the *local* pty of an
/// ssh session. With key auth the session can be ready for it before ssh has
/// switched that pty to raw mode, and until then it is cooked — where Darwin
/// keeps about a kilobyte of typed-ahead input in all. The injection is
/// several kilobytes; typed then, it was cut off and the remote prompt got
/// base64 junk (2026-10-08). Short lines alone don't fix it: CI showed the
/// total still being dropped. So it waits for the pty to go raw.
///
/// Stood in for here by a pty that stays cooked for a second (as it does
/// while ssh connects) before an interactive bash takes it over.
/// `ShellIntegrationRemoteTests` can't see this: it skips the local pty.
@MainActor
final class ShellIntegrationInjectionPtyTests: XCTestCase {
    private func screen(_ session: TerminalSession) -> String {
        AgentController.screenLines(session.terminalView.getTerminal())
    }

    func testTheInjectionWaitsUntilTheTerminalIsRawAndThenWorks() async throws {
        try await injects(into: "/bin/bash --norc --noprofile -i")
    }

    func testTheInjectionWorksInZshToo() async throws {
        try await injects(into: "/bin/zsh -f -i")
    }

    private func injects(into shell: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let sessions = SessionManager()
        sessions.localShell = ("/bin/sh", ["-c", "echo connecting; sleep 1; exec \(shell)"])
        sessions.openLocalShell()
        let session = try XCTUnwrap(sessions.tabs.last?.leaves.first)
        defer { sessions.tabs.forEach(sessions.closeTab) }
        let started = Date()
        var sentAt: Date?
        sessions.typeWhenReady(ShellIntegrationInjection.command, to: session, deadline: .now() + 15,
                               untilRaw: true) { sentAt = Date() }
        for _ in 0..<200 where sentAt == nil { try await Task.sleep(nanoseconds: 100_000_000) }
        let sent = try XCTUnwrap(sentAt, "never typed")
        XCTAssertGreaterThan(sent.timeIntervalSince(started), 0.9, "typed while the pty was still cooked",
                             file: file, line: line)

        // Reported through a file rather than the screen: what's being tested
        // is what the shell ran, not how a window drew it.
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("injected-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        session.sendText(" type __portside_preexec >/dev/null 2>&1 && touch '\(marker.path)'\r")
        for _ in 0..<150 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path),
                      "the integration isn't defined in the shell; screen: [\(screen(session))]", file: file, line: line)
    }

    /// dash has no hook to run before a command, so it gets the prompt-only
    /// integration: its prompt reports the last status and marks itself, and
    /// the line typed after it is read as the command. dash never puts the
    /// pty in raw mode (it has no line editor), so this types without
    /// waiting for raw.
    func testDashGetsPromptOnlyRecording() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/bin/dash"), "no /bin/dash")
        let sessions = SessionManager()
        sessions.capturesCommandOutput = true
        sessions.localShell = ("/bin/sh", ["-c", "PS1='$ ' exec /bin/dash -i"])
        sessions.openLocalShell()
        let session = try XCTUnwrap(sessions.tabs.last?.leaves.first)
        defer { sessions.tabs.forEach(sessions.closeTab) }
        for _ in 0..<100 where !screen(session).contains("$") { try await Task.sleep(nanoseconds: 100_000_000) }
        var sent = false
        sessions.typeWhenReady(ShellIntegrationInjection.command, to: session, deadline: .now() + 15,
                               untilRaw: false) { sent = true }
        for _ in 0..<150 where !session.terminalView.sawShellIntegration { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertTrue(sent)
        XCTAssertTrue(session.terminalView.sawShellIntegration, "no prompt marker\n\(screen(session))")

        // One at a time, as `send --wait` does: a line typed ahead is echoed
        // by the tty into the running command's output, and the prompt after
        // it has nothing typed to read.
        var commands: [CommandOutputCapture.Command] = []
        for (n, line) in ["echo hi-$((6*7))", "false"].enumerated() {
            session.sendText(line + "\r")
            for _ in 0..<100 {
                commands = session.terminalView.outputCapture?.completed ?? []
                if commands.count > n { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        XCTAssertEqual(commands.map(\.command), ["echo hi-$((6*7))", "false"], screen(session))
        XCTAssertEqual(commands.map(\.output), ["hi-42", ""])
        XCTAssertEqual(commands.map(\.exitCode), [0, 1])
        XCTAssertTrue(commands.allSatisfy(\.inferred))
        for complaint in ["not found", "syntax error", "unexpected", "Bad substitution"] {
            XCTAssertFalse(screen(session).contains(complaint), "\(complaint)\n\(screen(session))")
        }
    }

    /// A pty that never goes raw doesn't get the injection at all.
    func testNothingIsTypedIfTheTerminalNeverGoesRaw() async throws {
        let sessions = SessionManager()
        sessions.localShell = ("/bin/sh", ["-c", "sleep 30"])
        sessions.openLocalShell()
        let session = try XCTUnwrap(sessions.tabs.last?.leaves.first)
        defer { sessions.tabs.forEach(sessions.closeTab) }
        var typed = false
        sessions.typeWhenReady(ShellIntegrationInjection.command, to: session, deadline: .now() + 1,
                               untilRaw: true) { typed = true }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertFalse(typed)
    }

    /// Each line typed has to fit a canonical line buffer anyway — a remote
    /// host may read it in canonical mode too.
    func testEveryLineFitsACanonicalLineBuffer() {
        for line in ShellIntegrationInjection.command.split(separator: "\r") {
            XCTAssertLessThan(line.utf8.count, 1000, String(line.prefix(60)))
        }
    }
}
