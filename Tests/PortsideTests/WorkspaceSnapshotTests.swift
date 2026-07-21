import XCTest
@testable import Portside

/// The restore snapshot model and its pure replay planner (no terminals spawned).
final class WorkspaceSnapshotTests: XCTestCase {

    private func host(_ name: String) -> SessionEntry {
        SessionEntry(name: name, hostname: "\(name).example.com")
    }

    private func item(_ kind: WorkspaceSnapshot.Item.Kind, multiExec: Bool = true) -> WorkspaceSnapshot.Item {
        WorkspaceSnapshot.Item(kind: kind, includedInMultiExec: multiExec)
    }

    // MARK: - Codable

    func testSnapshotRoundTrips() throws {
        let a = UUID(), b = UUID()
        let snap = WorkspaceSnapshot(items: [
            item(.host(a), multiExec: true),
            item(.localShell, multiExec: false),
            item(.host(b), multiExec: true),
        ], selectedIndex: 2)

        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
        XCTAssertEqual(decoded, snap)
    }

    func testEmptyByDefault() {
        XCTAssertTrue(WorkspaceSnapshot().isEmpty)
        XCTAssertFalse(WorkspaceSnapshot(items: [item(.localShell)]).isEmpty)
    }

    // MARK: - Planner

    func testPlanResolvesHostsAndLocalShells() {
        let a = host("a"), b = host("b")
        let library = [a.id: a, b.id: b]
        let snap = WorkspaceSnapshot(items: [
            item(.host(a.id), multiExec: false),
            item(.localShell, multiExec: true),
            item(.host(b.id), multiExec: true),
        ], selectedIndex: 1)

        let plan = snap.plan { library[$0] }

        XCTAssertEqual(plan.actions, [
            .connect(a, includedInMultiExec: false),
            .localShell(includedInMultiExec: true),
            .connect(b, includedInMultiExec: true),
        ])
        XCTAssertEqual(plan.selectedActionIndex, 1)
    }

    func testPlanSkipsDeletedHostsAndRemapsSelection() {
        let a = host("a"), c = host("c")
        let library = [a.id: a, c.id: c]     // 'b' was deleted
        let bID = UUID()
        let snap = WorkspaceSnapshot(items: [
            item(.host(a.id)),
            item(.host(bID)),   // gone
            item(.host(c.id)),  // was selected at index 2
        ], selectedIndex: 2)

        let plan = snap.plan { library[$0] }

        XCTAssertEqual(plan.actions, [
            .connect(a, includedInMultiExec: true),
            .connect(c, includedInMultiExec: true),
        ])
        // c moved from original index 2 to action index 1.
        XCTAssertEqual(plan.selectedActionIndex, 1)
    }

    func testPlanSelectedDeletedYieldsNilSelection() {
        let a = host("a")
        let library = [a.id: a]
        let snap = WorkspaceSnapshot(items: [
            item(.host(a.id)),
            item(.host(UUID())),  // deleted, and it was selected
        ], selectedIndex: 1)

        let plan = snap.plan { library[$0] }

        XCTAssertEqual(plan.actions, [.connect(a, includedInMultiExec: true)])
        XCTAssertNil(plan.selectedActionIndex)
    }

    func testPlanEmptyWhenAllHostsDeleted() {
        let snap = WorkspaceSnapshot(items: [item(.host(UUID())), item(.host(UUID()))],
                                     selectedIndex: 0)
        let plan = snap.plan { _ in nil }
        XCTAssertTrue(plan.actions.isEmpty)
        XCTAssertNil(plan.selectedActionIndex)
    }

    func testPlanNilSelectedIndex() {
        let a = host("a")
        let snap = WorkspaceSnapshot(items: [item(.host(a.id))], selectedIndex: nil)
        let plan = snap.plan { _ in a }
        XCTAssertEqual(plan.actions.count, 1)
        XCTAssertNil(plan.selectedActionIndex)
    }

    // MARK: - Store persistence

    func testWorkspacePersistsThroughStore() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-ws-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = SessionStore(fileURL: url)
        let a = host("a")
        let snap = WorkspaceSnapshot(items: [item(.host(a.id))], selectedIndex: 0)
        store.saveWorkspace(snap)

        let reloaded = SessionStore(fileURL: url)
        XCTAssertEqual(reloaded.workspace, snap)
    }

    func testSaveWorkspaceNoOpWhenUnchanged() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-ws-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = SessionStore(fileURL: url)
        let snap = WorkspaceSnapshot(items: [item(.localShell)], selectedIndex: 0)
        store.saveWorkspace(snap)
        // Saving the identical snapshot again should leave it equal (no throw / churn).
        store.saveWorkspace(snap)
        XCTAssertEqual(store.workspace, snap)
    }
}
