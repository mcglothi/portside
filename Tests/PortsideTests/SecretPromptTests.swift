import XCTest
@testable import Portside

/// The signal behind the post-connect fix.
///
/// A run-on-connect command used to be typed on a flat 1.2-second timer, which
/// loses the race against a password prompt, a slow ProxyJump chain, or MFA —
/// and losing it means the command is typed *into* the prompt, submitted as a
/// credential, and logged as a failed one by the server.
///
/// The whole fix rests on one claim: that a pty master reports the slave's
/// termios, and that a secret prompt shows there as echo off *with* canonical
/// mode on. The first version of this test asserted "a shell at its prompt has
/// echo on" — which is false once zsh's or bash's line editor is running (both
/// turn echo and canonical mode off), and only passed by catching the moment
/// before the editor started. So it's tested against a real shell, at a
/// settled prompt, with a real secret read.
@MainActor
final class SecretPromptTests: XCTestCase {

    /// Spins the run loop until `condition` holds, so the shell has time to act.
    private func wait(upTo seconds: TimeInterval, for condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    func testEchoOffOnARealShellIsVisibleAsReadingASecret() throws {
        let manager = SessionManager()
        defer { for s in manager.sessions { s.shutdown() } }
        manager.openLocalShell()
        let session = try XCTUnwrap(manager.selectedTab?.leaves.first)

        // Wait for the shell's line editor itself — echo and canonical mode
        // both off — rather than for a fixed time: a login shell with a heavy
        // rc took seven seconds to get there, and checking any earlier only
        // sees the startup window, when echo is still on and the bug can't show.
        func lineEditorRunning() -> Bool {
            var t = termios()
            guard let p = session.terminalView.process, tcgetattr(p.childfd, &t) == 0 else { return false }
            return t.c_lflag & tcflag_t(ECHO) == 0 && t.c_lflag & tcflag_t(ICANON) == 0
        }
        XCTAssertTrue(wait(upTo: 30) { session.isRunning && lineEditorRunning() },
                      "the shell never reached its line editor")
        XCTAssertFalse(session.isReadingSecret,
                       "an ordinary prompt (echo off, raw) is not a password prompt")

        // `read -s` sets the tty exactly as readpassphrase/ssh/sudo do.
        session.sendText("read -s portside_secret\r")
        XCTAssertTrue(wait(upTo: 10) { session.isReadingSecret },
                      "a secret read must be visible from the master — "
                      + "if this fails the post-connect guard does nothing at all")

        session.sendText("hunter2\r")
        XCTAssertTrue(wait(upTo: 10) { !session.isReadingSecret },
                      "and it must clear again, or a command would never be sent")
    }

    func testASessionThatHasExitedIsNotReadingAnything() throws {
        let manager = SessionManager()
        defer { for s in manager.sessions { s.shutdown() } }
        manager.openLocalShell()
        let session = try XCTUnwrap(manager.selectedTab?.leaves.first)
        XCTAssertTrue(wait(upTo: 10) { session.isRunning })

        session.shutdown()

        XCTAssertTrue(wait(upTo: 10) { !session.isReadingSecret },
                      "a dead session must not hold the command back forever")
    }
}
