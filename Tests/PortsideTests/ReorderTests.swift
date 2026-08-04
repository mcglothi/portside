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
    // MARK: - Grid

    func testSwappingTwoPanesExchangesThem() throws {
        let manager = manager(tabs: 4)
        defer { shutDown(manager) }
        manager.setGridView(true)
        let tab = try XCTUnwrap(manager.selectedTab)
        let panes = tab.leaves.map(\.id)

        manager.swapPanes(panes[0], panes[3])

        XCTAssertEqual(tab.leaves.map(\.id), [panes[3], panes[1], panes[2], panes[0]])
    }

    /// The property that makes grid reordering worth having: the grid's pane
    /// order *is* the tab order, so rearranging the grid and then leaving it
    /// hands the tabs back rearranged, with no write-back step to forget.
    func testRearrangingTheGridSurvivesLeavingIt() throws {
        let manager = manager(tabs: 4)
        defer { shutDown(manager) }
        let originalTabOrder = manager.tabs.map { $0.leaves[0].id }
        manager.setGridView(true)
        let panes = try XCTUnwrap(manager.selectedTab).leaves.map(\.id)

        manager.swapPanes(panes[0], panes[3])
        manager.setGridView(false)

        XCTAssertEqual(manager.tabs.map { $0.leaves[0].id },
                       [originalTabOrder[3], originalTabOrder[1],
                        originalTabOrder[2], originalTabOrder[0]])
    }

    func testSwappingAPaneWithItselfChangesNothing() throws {
        let manager = manager(tabs: 2)
        defer { shutDown(manager) }
        manager.setGridView(true)
        let tab = try XCTUnwrap(manager.selectedTab)
        let panes = tab.leaves.map(\.id)

        manager.swapPanes(panes[0], panes[0])

        XCTAssertEqual(tab.leaves.map(\.id), panes)
    }

    func testSwappingWithAPaneFromAnotherTabIsIgnored() throws {
        let manager = manager(tabs: 3)
        defer { shutDown(manager) }
        let tab = try XCTUnwrap(manager.selectedTab)
        let mine = try XCTUnwrap(tab.leaves.first).id
        let elsewhere = try XCTUnwrap(manager.tabs.first { $0.id != tab.id }?.leaves.first).id

        manager.swapPanes(mine, elsewhere)

        XCTAssertEqual(tab.leaves.map(\.id), [mine])
    }
    // MARK: - Keyboard

    func testMovingTheSelectedTabWithTheKeyboard() throws {
        let manager = manager(tabs: 3)
        defer { shutDown(manager) }
        let ids = manager.tabs.map(\.id)
        manager.selectedTabID = ids[0]

        manager.moveSelectedTab(forward: true)

        XCTAssertEqual(manager.tabs.map(\.id), [ids[1], ids[0], ids[2]])
        XCTAssertEqual(manager.selectedTabID, ids[0], "the tab you moved stays selected")
    }

    /// Stops rather than wrapping: rearranging is a placing motion, and a tab
    /// leaping from one end of the bar to the other is rarely what you meant.
    func testMovingStopsAtTheEnds() throws {
        let manager = manager(tabs: 2)
        defer { shutDown(manager) }
        let ids = manager.tabs.map(\.id)
        manager.selectedTabID = ids[0]

        XCTAssertFalse(manager.canMoveSelectedTab(forward: false))
        manager.moveSelectedTab(forward: false)

        XCTAssertEqual(manager.tabs.map(\.id), ids)
    }

    // MARK: - What reordering must not disturb

    /// Free today, because `includedInMultiExec` lives on the session and a swap
    /// carries the session with it. Pinned because "the pane I excluded became
    /// included when I moved it" is a broadcast reaching a host you took out.
    func testSwappingAPaneKeepsItsMultiExecInclusion() throws {
        let manager = manager(tabs: 3)
        defer { shutDown(manager) }
        manager.setGridView(true)
        let tab = try XCTUnwrap(manager.selectedTab)
        let panes = tab.leaves
        panes[0].includedInMultiExec = false

        manager.swapPanes(panes[0].id, panes[2].id)

        let moved = try XCTUnwrap(tab.leaves.first { $0.id == panes[0].id })
        XCTAssertFalse(moved.includedInMultiExec, "exclusion travels with the pane")
        XCTAssertEqual(tab.leaves.map(\.id).firstIndex(of: panes[0].id), 2)
    }

    /// Also free — `captureGroupLayout` snapshots `tab.root`, which is what the
    /// swap rewrote. Pinned because a group that quietly forgets a rearrangement
    /// is the same complaint as a rename that doesn't stick.
    func testAGroupTabCapturesARearrangedLayout() throws {
        let manager = manager(tabs: 3)
        defer { shutDown(manager) }
        manager.setGridView(true)
        let tab = try XCTUnwrap(manager.selectedTab)
        let groupID = UUID()
        tab.groupID = groupID

        var captured: WorkspaceSnapshot.TabSnapshot?
        var capturedID: UUID?
        manager.onGroupLayoutChange = { id, snapshot, _ in capturedID = id; captured = snapshot }

        // Exclude the first pane so its leaf is identifiable in the snapshot,
        // which records membership but not session ids.
        let panes = tab.leaves
        panes[0].includedInMultiExec = false
        manager.swapPanes(panes[0].id, panes[2].id)
        manager.captureGroupLayoutIfLinked(tab)

        let snapshot = try XCTUnwrap(captured)
        XCTAssertEqual(capturedID, groupID)
        XCTAssertEqual(inclusionOrder(of: snapshot.root), [true, true, false],
                       "the layout written back is the rearranged one, not the original")
    }

    /// MultiExec membership per leaf, left to right — a stand-in for identity in
    /// a snapshot that records what a pane *is*, not which session filled it.
    private func inclusionOrder(of node: WorkspaceSnapshot.PaneSnapshot) -> [Bool] {
        switch node {
        case .leaf(let leaf): return [leaf.includedInMultiExec]
        case .split(_, let children): return children.flatMap(inclusionOrder)
        }
    }

}
