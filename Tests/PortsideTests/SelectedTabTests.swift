import XCTest
@testable import Portside

/// `selectedTab` is what every tab-scoped command reads through, so a nil here
/// is not a cosmetic problem: arm, broadcast, split, close and zoom all quietly
/// do nothing, and `SessionArea` used to draw nothing at all.
@MainActor
final class SelectedTabTests: XCTestCase {

    func testSelectedTabResolvesTheSelectedID() {
        let manager = SessionManager()
        manager.openStartTab()
        manager.openStartTab()
        let second = manager.tabs[1]
        manager.selectedTabID = second.id

        XCTAssertIdentical(manager.selectedTab, second)
    }

    func testAStaleSelectionStillResolvesToATab() {
        // The teardown case. Removal paths do reassign the id, but when one
        // doesn't, every tab-scoped command silently becomes a no-op and the
        // window renders nothing — while still looking normal.
        let manager = SessionManager()
        manager.openStartTab()
        manager.openStartTab()
        manager.selectedTabID = UUID()   // names a tab that isn't here

        XCTAssertNotNil(manager.selectedTab,
                        "a stale id must not leave the app with no active tab")
        XCTAssertIdentical(manager.selectedTab, manager.tabs.last)
    }

    func testNoTabsMeansNoSelectedTab() {
        // The genuinely empty case still has to report empty — the fallback
        // must not invent a tab, or `SessionArea` would try to render one.
        let manager = SessionManager()
        XCTAssertTrue(manager.tabs.isEmpty)
        XCTAssertNil(manager.selectedTab)
    }

    /// The invariant `SessionArea` now relies on: whenever there is anything to
    /// show, there is a tab to show it in. With this holding, the view's
    /// `else` can only be the genuinely-empty case.
    func testThereIsAlwaysATabWheneverThereAreSessions() {
        let manager = SessionManager()
        manager.openStartTab()
        manager.selectedTabID = UUID()

        if !manager.sessions.isEmpty {
            XCTAssertNotNil(manager.selectedTab)
        }
        // And with tabs present at all, selection resolves regardless of id.
        XCTAssertFalse(manager.tabs.isEmpty)
        XCTAssertNotNil(manager.selectedTab)
    }
}
