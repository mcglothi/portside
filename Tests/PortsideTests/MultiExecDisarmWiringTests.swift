import XCTest
@testable import Portside

/// The disarm *wiring*, not just the policy values.
///
/// This is the layer that was previously written off as untestable — nothing
/// in the suite constructed a `SessionManager`. It constructs fine, and the
/// rule that matters ("a reconnected pane must not rejoin a live broadcast")
/// only exists in that wiring, so it was going unchecked exactly where a
/// mistake costs the most.
///
/// These spawn real local shells, so each test closes what it opened.
@MainActor
final class MultiExecDisarmWiringTests: XCTestCase {
    private var manager: SessionManager!

    override func setUp() {
        super.setUp()
        manager = SessionManager()
    }

    override func tearDown() {
        for session in manager.sessions { session.shutdown() }
        manager = nil
        super.tearDown()
    }

    /// One armed tab holding one live local shell.
    private func armedTabWithShell() throws -> (Tab, TerminalSession) {
        manager.openLocalShell()
        let tab = try XCTUnwrap(manager.selectedTab)
        let session = try XCTUnwrap(tab.leaves.first)
        tab.broadcastArmed = true
        return (tab, session)
    }

    func testReconnectingAPaneDisarmsTheTab() throws {
        // The failure both external reviews called sharpest: a host drops,
        // comes back, and silently rejoins a live broadcast.
        let (tab, session) = try armedTabWithShell()
        XCTAssertTrue(tab.broadcastArmed)

        manager.reconnect(session)

        XCTAssertFalse(tab.broadcastArmed,
                       "a reconnected pane must not rejoin a live broadcast")
    }

    func testReconnectingSaysWhyItDisarmed() throws {
        // Disarming behind the user's back is only defensible if the app says
        // so — the banner vanishing is otherwise unexplained.
        let (_, session) = try armedTabWithShell()

        manager.reconnect(session)

        let notice = try XCTUnwrap(manager.disarmNotice)
        XCTAssertTrue(notice.message.contains("MultiExec disarmed"))
    }

    func testALocalShellIsNotNamedByItsLastCommand() throws {
        // A session with no library entry falls back to its title, which OSC
        // sets to the last command — so this read "exit reconnected" after the
        // shell was exited. Verified in the running app before it was fixed.
        let (_, session) = try armedTabWithShell()
        session.title = "exit"

        manager.reconnect(session)

        let notice = try XCTUnwrap(manager.disarmNotice)
        XCTAssertFalse(notice.message.contains("exit reconnected"),
                       "a local shell must not be named by whatever it last ran")
        XCTAssertTrue(notice.message.contains("a pane reconnected"))
    }

    func testReconnectingKeepsTheGroupIntact() throws {
        // Disarm without losing membership: re-arming should bring the same
        // group back rather than making the user rebuild it.
        let (_, session) = try armedTabWithShell()
        session.includedInMultiExec = true

        manager.reconnect(session)

        let replacement = try XCTUnwrap(manager.selectedTab?.leaves.first)
        XCTAssertNotEqual(replacement.id, session.id, "the pane was actually replaced")
        XCTAssertTrue(replacement.includedInMultiExec,
                      "membership carries over; only the arming is dropped")
    }

    func testReconnectingAnUnarmedTabRaisesNoNotice() throws {
        // No disarm happened, so there is nothing to explain — a notice here
        // would be noise on an ordinary reconnect.
        manager.openLocalShell()
        let tab = try XCTUnwrap(manager.selectedTab)
        let session = try XCTUnwrap(tab.leaves.first)
        XCTAssertFalse(tab.broadcastArmed)

        manager.reconnect(session)

        XCTAssertNil(manager.disarmNotice)
    }
}
