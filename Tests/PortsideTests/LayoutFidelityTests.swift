import XCTest
@testable import Portside

/// Whether a saved layout comes back the shape it went in.
///
/// This used to be about split *proportions*. It isn't any more: `fractions`
/// was removed once it turned out nothing ever set it from a user action and
/// nothing ever rendered it. What remains — and what a saved group or a
/// restored workspace actually depends on — is that the *structure* survives:
/// the same panes, in the same nesting, in the same order.
@MainActor
final class LayoutFidelityTests: XCTestCase {

    private func leaf(_ included: Bool = true) -> WorkspaceSnapshot.PaneSnapshot {
        .leaf(WorkspaceSnapshot.Leaf(kind: .localShell, includedInMultiExec: included))
    }

    private func leafCount(_ node: WorkspaceSnapshot.PaneSnapshot) -> Int {
        switch node {
        case .leaf: return 1
        case .split(_, let children): return children.reduce(0) { $0 + leafCount($1) }
        }
    }

    func testStructureSurvivesCodable() throws {
        let snapshot = WorkspaceSnapshot(tabs: [
            WorkspaceSnapshot.TabSnapshot(root: .split(
                orientation: .horizontal,
                children: [leaf(), .split(orientation: .vertical, children: [leaf(), leaf(false)])]))
        ])

        let decoded = try JSONDecoder().decode(
            WorkspaceSnapshot.self, from: JSONEncoder().encode(snapshot))

        XCTAssertEqual(decoded, snapshot, "nesting, order and membership must all round-trip")
    }

    /// The compatibility guarantee for removing `fractions`.
    func testASnapshotWrittenWithFractionsStillDecodes() throws {
        // Every library and group saved before the removal has this key. A
        // synthesized enum decoder ignores associated-value keys it doesn't
        // know, so they load — but that is exactly the kind of assumption that
        // deserves a test rather than a comment.
        let json = """
        {"tabs":[{"root":{"split":{"orientation":"horizontal",
                                   "fractions":[0.09,0.46,0.45],
                                   "children":[
            {"leaf":{"_0":{"kind":{"localShell":{}},"includedInMultiExec":true}}},
            {"leaf":{"_0":{"kind":{"localShell":{}},"includedInMultiExec":false}}}
          ]}}}],
         "selectedTabIndex":0,"wasGridView":false}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: json)

        guard case .split(let orientation, let children)? = decoded.tabs.first?.root else {
            return XCTFail("a pre-removal snapshot must still load")
        }
        XCTAssertEqual(orientation, .horizontal)
        XCTAssertEqual(children.count, 2)
    }

    func testCapturingALiveTabPreservesItsStructure() throws {
        let manager = SessionManager()
        defer { for s in manager.sessions { s.shutdown() } }
        manager.openLocalShell()
        manager.splitActivePane(.horizontal)
        manager.splitActivePane(.vertical)

        let tab = try XCTUnwrap(manager.selectedTab)
        let captured = manager.currentWorkspace

        XCTAssertEqual(captured.tabs.count, 1)
        XCTAssertEqual(leafCount(captured.tabs[0].root), tab.leaves.count,
                       "capture must record every pane the tab actually has")
    }

    func testReplayingASnapshotRebuildsTheSameStructure() throws {
        let manager = SessionManager()
        defer { for s in manager.sessions { s.shutdown() } }
        manager.openLocalShell()
        manager.splitActivePane(.horizontal)
        manager.splitActivePane(.vertical)
        let captured = manager.currentWorkspace

        let replayer = SessionManager()
        defer { for s in replayer.sessions { s.shutdown() } }
        replayer.restore(captured.plan { _ in nil })

        XCTAssertEqual(replayer.selectedTab?.leaves.count, manager.selectedTab?.leaves.count)
        XCTAssertEqual(replayer.currentWorkspace.tabs.first?.root,
                       captured.tabs.first?.root,
                       "a replayed tab must snapshot back to what it was built from")
    }

    func testTwoSplitsNestRatherThanWideningARow() throws {
        // Splitting the *active* pane, which is the one just created, nests.
        // Worth stating: it's why a three-pane tab isn't three equal columns,
        // and it was mistaken for lost proportions before `fractions` went.
        let manager = SessionManager()
        defer { for s in manager.sessions { s.shutdown() } }
        manager.openLocalShell()
        manager.splitActivePane(.horizontal)
        manager.splitActivePane(.horizontal)

        let tab = try XCTUnwrap(manager.selectedTab)
        XCTAssertEqual(tab.leaves.count, 3)
        guard case .split(_, _, let children)? = tab.root else { return XCTFail("expected a split") }
        XCTAssertEqual(children.count, 2, "nested, not a flat row of three")
    }

    func testRemovingAPaneCollapsesASingleChildSplit() throws {
        // The tree algebra that used to renormalise fractions still has to
        // collapse a split left with one child.
        let manager = SessionManager()
        defer { for s in manager.sessions { s.shutdown() } }
        manager.openLocalShell()
        manager.splitActivePane(.horizontal)
        let tab = try XCTUnwrap(manager.selectedTab)
        XCTAssertEqual(tab.leaves.count, 2)

        manager.close(try XCTUnwrap(tab.leaves.last))

        guard case .leaf? = manager.selectedTab?.root else {
            return XCTFail("a two-way split losing one child should collapse to a leaf")
        }
    }
}
