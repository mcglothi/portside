import XCTest
@testable import Portside

/// What a tab calls itself.
///
/// Reported from use: a tab holding a saved group still named itself after
/// whichever host happened to be first in it, and renaming a tab reverted the
/// moment MultiExec gathered it into a grid — which reads as the rename simply
/// not having worked.
@MainActor
final class TabTitleTests: XCTestCase {

    private func groupNamed(_ id: UUID, _ name: String) -> (UUID) -> String? {
        { $0 == id ? name : nil }
    }

    private func tabWithShells(_ manager: SessionManager, count: Int) -> Tab {
        manager.openLocalShell()
        for _ in 1..<count { manager.splitActivePane(.horizontal) }
        return manager.selectedTab!
    }

    // MARK: - Precedence

    func testAGroupTabIsNamedAfterTheGroup() throws {
        let manager = SessionManager()
        defer { for s in manager.sessions { s.shutdown() } }
        let tab = tabWithShells(manager, count: 2)
        let groupID = UUID()
        tab.groupID = groupID

        XCTAssertEqual(tabDisplayTitle(tab, groupName: groupNamed(groupID, "TEST-GROUP1")),
                       "TEST-GROUP1")
    }

    func testAnExplicitRenameBeatsTheGroupName() throws {
        // The one the user typed wins over the one the app inferred.
        let manager = SessionManager()
        defer { for s in manager.sessions { s.shutdown() } }
        let tab = tabWithShells(manager, count: 2)
        let groupID = UUID()
        tab.groupID = groupID
        tab.customTitle = "Patching"

        XCTAssertEqual(tabDisplayTitle(tab, groupName: groupNamed(groupID, "TEST-GROUP1")),
                       "Patching")
    }

    func testAGroupThatNoLongerExistsFallsBackToTheHosts() throws {
        // Deleted group, tab still open: name it after what's in it rather
        // than showing nothing.
        let manager = SessionManager()
        defer { for s in manager.sessions { s.shutdown() } }
        let tab = tabWithShells(manager, count: 2)
        tab.groupID = UUID()

        let title = tabDisplayTitle(tab) { _ in nil }
        XCTAssertTrue(title.hasSuffix("+1"), "got: \(title)")
    }

    // MARK: - Multi-pane naming

    func testASinglePaneTabIsNamedAfterItsHost() throws {
        let manager = SessionManager()
        defer { for s in manager.sessions { s.shutdown() } }
        let tab = tabWithShells(manager, count: 1)

        let title = tabDisplayTitle(tab) { _ in nil }
        XCTAssertFalse(title.contains("+"), "a lone pane needs no count: \(title)")
    }

    func testAMultiPaneTabCountsTheRest() throws {
        // Not "new group": a split tab is often just a split, and may never
        // become a group. The count says what it is without claiming more.
        let manager = SessionManager()
        defer { for s in manager.sessions { s.shutdown() } }
        let tab = tabWithShells(manager, count: 3)

        let title = tabDisplayTitle(tab) { _ in nil }
        XCTAssertTrue(title.hasSuffix("+2"), "got: \(title)")
    }

    func testTheTitleDoesNotChangeAsFocusMovesBetweenPanes() throws {
        // It used to read from the *active* leaf, so clicking around a grid
        // renamed the tab under you.
        let manager = SessionManager()
        defer { for s in manager.sessions { s.shutdown() } }
        let tab = tabWithShells(manager, count: 3)
        let before = tabDisplayTitle(tab) { _ in nil }

        tab.activePaneID = tab.leaves.last?.id

        XCTAssertEqual(tabDisplayTitle(tab) { _ in nil }, before)
    }

    // MARK: - Surviving the grid merge

    func testARenameSurvivesBeingGatheredIntoAGrid() throws {
        // The reported bug: rename a tab, arm MultiExec, and the name reverts.
        let manager = SessionManager()
        defer { for s in manager.sessions { s.shutdown() } }
        manager.openLocalShell()
        manager.selectedTab?.customTitle = "Splunk"
        manager.openLocalShell()          // a second tab, so gridding engages

        manager.setGridView(true)

        XCTAssertEqual(manager.tabs.count, 1, "the tabs merged")
        XCTAssertEqual(manager.selectedTab?.customTitle, "Splunk")
    }

    func testTwoRenamedTabsMergingKeepNeitherName() throws {
        // No non-arbitrary answer with several, and picking one would be worse
        // than showing what the grid actually holds.
        let manager = SessionManager()
        defer { for s in manager.sessions { s.shutdown() } }
        manager.openLocalShell()
        manager.selectedTab?.customTitle = "Splunk"
        manager.openLocalShell()
        manager.selectedTab?.customTitle = "Kafka"

        manager.setGridView(true)

        XCTAssertNil(manager.selectedTab?.customTitle)
    }

    func testAGridMergeDoesNotInheritAGroupLink() throws {
        // A grid built from several tabs is not the group any one of them came
        // from — inheriting the link would have closing it write the merged
        // layout back over the saved group.
        let manager = SessionManager()
        defer { for s in manager.sessions { s.shutdown() } }
        manager.openLocalShell()
        manager.selectedTab?.groupID = UUID()
        manager.openLocalShell()

        manager.setGridView(true)

        XCTAssertNil(manager.selectedTab?.groupID)
    }
}
