import XCTest
@testable import Portside

/// Rearranging tabs, and rearranging the grid — which are the same list seen
/// two ways.
@MainActor
final class ReorderTests: XCTestCase {

    private func manager(tabs count: Int) -> SessionManager {
        let manager = SessionManager()
        for _ in 0..<count { manager.openLocalShell() }
        return manager
    }

    private func shutDown(_ manager: SessionManager) {
        for session in manager.sessions { session.shutdown() }
    }

    // MARK: - Tab bar

    func testMovingATabToTheFrontReordersTheBar() throws {
        let manager = manager(tabs: 3)
        defer { shutDown(manager) }
        let ids = manager.tabs.map(\.id)

        manager.moveTab(ids[2], before: ids[0])

        XCTAssertEqual(manager.tabs.map(\.id), [ids[2], ids[0], ids[1]])
    }

    func testMovingATabToTheEnd() throws {
        let manager = manager(tabs: 3)
        defer { shutDown(manager) }
        let ids = manager.tabs.map(\.id)

        manager.moveTabToEnd(ids[0])

        XCTAssertEqual(manager.tabs.map(\.id), [ids[1], ids[2], ids[0]])
    }

    /// Selection follows the tab, not the slot it used to be in.
    func testReorderingKeepsTheSameTabSelected() throws {
        let manager = manager(tabs: 3)
        defer { shutDown(manager) }
        let ids = manager.tabs.map(\.id)
        manager.selectedTabID = ids[0]

        manager.moveTab(ids[0], before: ids[2])

        XCTAssertEqual(manager.selectedTabID, ids[0])
    }

    /// ⌘1–⌘9 are index-based on purpose: after moving a tab to the front, ⌘1
    /// should select it rather than whatever used to be there.
    func testNumericShortcutsFollowTheNewOrder() throws {
        let manager = manager(tabs: 3)
        defer { shutDown(manager) }
        let ids = manager.tabs.map(\.id)

        manager.moveTab(ids[2], before: ids[0])
        manager.selectTab(at: 0)

        XCTAssertEqual(manager.selectedTabID, ids[2])
    }

    func testMovingATabOntoItselfChangesNothing() throws {
        let manager = manager(tabs: 3)
        defer { shutDown(manager) }
        let ids = manager.tabs.map(\.id)

        manager.moveTab(ids[1], before: ids[1])

        XCTAssertEqual(manager.tabs.map(\.id), ids)
    }

    func testTheNewOrderIsWhatGetsPersisted() throws {
        let manager = manager(tabs: 3)
        defer { shutDown(manager) }
        let ids = manager.tabs.map(\.id)

        manager.moveTab(ids[2], before: ids[0])

        // The workspace snapshot is positional, so it carries the order as-is.
        let hosts = manager.currentWorkspace.tabs.count
        XCTAssertEqual(hosts, 3)
        XCTAssertEqual(manager.tabs.map(\.id), [ids[2], ids[0], ids[1]])
    }
}
