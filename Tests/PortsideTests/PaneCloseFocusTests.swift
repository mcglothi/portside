import XCTest
@testable import Portside

/// Where focus lands after closing a pane.
///
/// Reported from use: holding ⌃D to clear a grid works for the first few panes
/// and then stops, leaving the last couple to be clicked on individually. ⌃D
/// only closes a dead pane when that pane is the window's first responder, so
/// once focus stopped following the model the key had nothing to act on.
@MainActor
final class PaneCloseFocusTests: XCTestCase {

    /// One tab of `count` panes, focused on the first.
    private func tab(withPanes count: Int, in manager: SessionManager) -> Tab {
        manager.openLocalShell()
        for _ in 1..<count { manager.splitActivePane(.horizontal) }
        let tab = manager.selectedTab!
        tab.activePaneID = tab.leaves.first?.id
        return tab
    }

    func testFocusMovesToTheNextPaneNotBackToTheFirst() throws {
        // It used to jump to `leaves.first` on every close, which throws you to
        // the far side of the grid each time.
        let manager = SessionManager()
        defer { for s in manager.sessions { s.shutdown() } }
        let tab = self.tab(withPanes: 3, in: manager)
        let order = tab.leaves
        tab.activePaneID = order[1].id

        manager.close(order[1])

        XCTAssertEqual(tab.leaves.count, 2)
        XCTAssertEqual(tab.activePaneID, order[2].id,
                       "focus should land on the pane that took its place")
    }

    func testClosingTheLastPaneFallsBackToThePreviousOne() throws {
        let manager = SessionManager()
        defer { for s in manager.sessions { s.shutdown() } }
        let tab = self.tab(withPanes: 3, in: manager)
        let order = tab.leaves
        tab.activePaneID = order[2].id

        manager.close(order[2])

        XCTAssertEqual(tab.activePaneID, order[1].id,
                       "nothing after it, so the one before takes focus")
    }

    func testEveryCloseLeavesAValidActivePane() throws {
        // The ⌃D-spam case: close repeatedly and the tab must always have a
        // live pane marked active, or the next key press has no target.
        let manager = SessionManager()
        defer { for s in manager.sessions { s.shutdown() } }
        let tab = self.tab(withPanes: 5, in: manager)

        for _ in 0..<4 {
            let active = try XCTUnwrap(tab.activeLeaf)
            manager.close(active)
            let remaining = tab.leaves
            guard !remaining.isEmpty else { break }
            XCTAssertNotNil(tab.activePaneID)
            XCTAssertTrue(remaining.contains { $0.id == tab.activePaneID },
                          "active pane must be one that still exists")
        }
    }

    func testClosingAPaneThatIsNotFocusedLeavesFocusAlone() throws {
        let manager = SessionManager()
        defer { for s in manager.sessions { s.shutdown() } }
        let tab = self.tab(withPanes: 3, in: manager)
        let order = tab.leaves
        tab.activePaneID = order[0].id

        manager.close(order[2])

        XCTAssertEqual(tab.activePaneID, order[0].id,
                       "closing something else must not move the user")
    }
}
