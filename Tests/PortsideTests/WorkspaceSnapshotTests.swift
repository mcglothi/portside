import XCTest
@testable import Portside

/// The restore snapshot model and its pure tree planner (no terminals spawned).
final class WorkspaceSnapshotTests: XCTestCase {

    private func host(_ name: String) -> SessionEntry {
        SessionEntry(name: name, hostname: "\(name).example.com")
    }

    private func hostLeaf(_ id: UUID, multiExec: Bool = true) -> WorkspaceSnapshot.PaneSnapshot {
        .leaf(.init(kind: .host(id), includedInMultiExec: multiExec))
    }

    private func shellLeaf(multiExec: Bool = true) -> WorkspaceSnapshot.PaneSnapshot {
        .leaf(.init(kind: .localShell, includedInMultiExec: multiExec))
    }

    private func tab(_ root: WorkspaceSnapshot.PaneSnapshot) -> WorkspaceSnapshot.TabSnapshot {
        .init(root: root)
    }

    // MARK: - Codable

    func testTreeSnapshotRoundTrips() throws {
        let a = UUID(), b = UUID()
        let snap = WorkspaceSnapshot(tabs: [
            tab(.split(orientation: .horizontal, children: [hostLeaf(a), shellLeaf(multiExec: false)],
                       fractions: [0.5, 0.5])),
            tab(hostLeaf(b)),
        ], selectedTabIndex: 1)

        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
        XCTAssertEqual(decoded, snap)
    }

    func testDecodesLegacyFlatSnapshot() throws {
        // A v1 workspace: flat `items` + `selectedIndex`, no `tabs`.
        let id = UUID().uuidString
        let json = """
        {"items":[{"kind":{"host":{"_0":"\(id)"}},"includedInMultiExec":true},
                  {"kind":{"localShell":{}},"includedInMultiExec":false}],
         "selectedIndex":1}
        """
        let snap = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snap.tabs.count, 2)          // each item → single-leaf tab
        XCTAssertEqual(snap.selectedTabIndex, 1)
        if case .leaf(let leaf) = snap.tabs[0].root, case .host(let decodedID) = leaf.kind {
            XCTAssertEqual(decodedID.uuidString, id)
        } else {
            XCTFail("first tab should be a single host leaf")
        }
    }

    func testEmptyByDefault() {
        XCTAssertTrue(WorkspaceSnapshot().isEmpty)
        XCTAssertFalse(WorkspaceSnapshot(tabs: [tab(shellLeaf())]).isEmpty)
    }

    // MARK: - Planner

    func testPlanResolvesTreeAndCountsPanes() {
        let a = host("a"), b = host("b")
        let library = [a.id: a, b.id: b]
        let snap = WorkspaceSnapshot(tabs: [
            tab(.split(orientation: .vertical,
                       children: [hostLeaf(a.id, multiExec: false), shellLeaf()],
                       fractions: [0.5, 0.5])),
            tab(hostLeaf(b.id)),
        ], selectedTabIndex: 1)

        let plan = snap.plan { library[$0] }
        XCTAssertEqual(plan.tabs.count, 2)
        XCTAssertEqual(plan.paneCount, 3)
        XCTAssertEqual(plan.selectedTabIndex, 1)

        // First tab is a vertical split of a connect + a local shell.
        guard case .split(let orientation, let children, _) = plan.tabs[0].root else {
            return XCTFail("expected a split")
        }
        XCTAssertEqual(orientation, .vertical)
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(children[0], .leaf(.connect(a, includedInMultiExec: false)))
        XCTAssertEqual(children[1], .leaf(.localShell(includedInMultiExec: true)))
    }

    func testPlanPrunesDeletedHostAndCollapsesSplit() {
        let a = host("a")
        let library = [a.id: a]     // 'b' was deleted
        let snap = WorkspaceSnapshot(tabs: [
            tab(.split(orientation: .horizontal, children: [hostLeaf(a.id), hostLeaf(UUID())],
                       fractions: [0.5, 0.5])),
        ], selectedTabIndex: 0)

        let plan = snap.plan { library[$0] }
        XCTAssertEqual(plan.tabs.count, 1)
        // The split collapsed to the surviving host leaf.
        XCTAssertEqual(plan.tabs[0].root, .leaf(.connect(a, includedInMultiExec: true)))
    }

    func testPlanDropsFullyDeletedTabAndRemapsSelection() {
        let a = host("a")
        let library = [a.id: a]
        let snap = WorkspaceSnapshot(tabs: [
            tab(hostLeaf(UUID())),   // all-deleted → dropped
            tab(hostLeaf(a.id)),     // was selected at index 1
        ], selectedTabIndex: 1)

        let plan = snap.plan { library[$0] }
        XCTAssertEqual(plan.tabs.count, 1)
        XCTAssertEqual(plan.selectedTabIndex, 0)   // remapped after the drop
    }

    func testPlanEmptyWhenEverythingDeleted() {
        let snap = WorkspaceSnapshot(tabs: [tab(hostLeaf(UUID())), tab(hostLeaf(UUID()))],
                                     selectedTabIndex: 0)
        let plan = snap.plan { _ in nil }
        XCTAssertTrue(plan.tabs.isEmpty)
        XCTAssertNil(plan.selectedTabIndex)
    }

    // MARK: - Store persistence

    func testWorkspacePersistsThroughStore() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-ws-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = SessionStore(fileURL: url)
        let snap = WorkspaceSnapshot(tabs: [tab(shellLeaf())], selectedTabIndex: 0)
        store.saveWorkspace(snap)

        let reloaded = SessionStore(fileURL: url)
        XCTAssertEqual(reloaded.workspace, snap)
    }
}
