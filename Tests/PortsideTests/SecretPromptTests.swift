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
/// termios, so a cleared `ECHO` bit is a direct reading of "something is asking
/// for a secret". If that claim is wrong the fix is inert and looks fine, so it
/// is tested against a real shell rather than asserted in a comment.
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

        // Let the shell come up and settle at a prompt.
        XCTAssertTrue(wait(upTo: 10) { session.isRunning && !session.isReadingSecret },
                      "a shell at its prompt has echo on")

        // `stty -echo` is exactly what ssh/sudo/PAM do before reading a secret.
        session.sendText("stty -echo\r")
        XCTAssertTrue(wait(upTo: 10) { session.isReadingSecret },
                      "echo off on the slave must be visible from the master — "
                      + "if this fails the post-connect guard does nothing at all")

        session.sendText("stty echo\r")
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
