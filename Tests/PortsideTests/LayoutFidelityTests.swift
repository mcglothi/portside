import XCTest
@testable import Portside

/// Whether a saved layout comes back the shape it went in.
///
/// Written after a group reopened with visibly different pane proportions from
/// the tab it was saved from. The question that needs settling first is where
/// the loss happens: capture, replay, or neither (and the live view was the
/// odd one all along).
@MainActor
final class LayoutFidelityTests: XCTestCase {

    private func leaf(_ included: Bool = true) -> WorkspaceSnapshot.PaneSnapshot {
        .leaf(WorkspaceSnapshot.Leaf(kind: .localShell, includedInMultiExec: included))
    }

    /// Fractions survive an encode/decode of the snapshot itself.
    func testUnevenFractionsSurviveCodable() throws {
        let uneven: [CGFloat] = [0.09, 0.46, 0.45]
        let snapshot = WorkspaceSnapshot(tabs: [
            WorkspaceSnapshot.TabSnapshot(root: .split(
                orientation: .horizontal,
                children: [leaf(), leaf(), leaf()],
                fractions: uneven))
        ])

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)

        guard case .split(_, _, let fractions)? = decoded.tabs.first?.root else {
            return XCTFail("expected a split")
        }
        XCTAssertEqual(fractions, uneven, "persistence must not round the layout off")
    }

    /// Fractions survive the plan step that sits between snapshot and rebuild.
    func testUnevenFractionsSurviveThePlan() throws {
        let uneven: [CGFloat] = [0.09, 0.46, 0.45]
        let snapshot = WorkspaceSnapshot(tabs: [
            WorkspaceSnapshot.TabSnapshot(root: .split(
                orientation: .horizontal,
                children: [leaf(), leaf(), leaf()],
                fractions: uneven))
        ])

        let plan = snapshot.plan { _ in nil }   // local shells need no lookup

        guard case .split(_, _, let fractions)? = plan.tabs.first?.root else {
            return XCTFail("expected a split")
        }
        XCTAssertEqual(fractions, uneven, "planning must not renormalise an intact layout")
    }

    /// The full loop: build a real tab, snapshot it, and compare.
    func testCapturingALiveTabPreservesItsFractions() throws {
        let manager = SessionManager()
        defer { for s in manager.sessions { s.shutdown() } }
        manager.openLocalShell()
        manager.splitActivePane(.horizontal)
        manager.splitActivePane(.horizontal)

        let tab = try XCTUnwrap(manager.selectedTab)
        guard case .split(_, _, _, let live)? = tab.root else {
            return XCTFail("expected a split after two splits, got \(String(describing: tab.root))")
        }

        let captured = manager.currentWorkspace
        guard case .split(_, _, let saved)? = captured.tabs.first?.root else {
            return XCTFail("expected a split in the snapshot")
        }

        XCTAssertEqual(saved, live, "capture must record the layout the tab actually has")
    }

    /// And back out again, which is what a group launch does.
    func testReplayingASnapshotRebuildsTheSameFractions() throws {
        let manager = SessionManager()
        defer { for s in manager.sessions { s.shutdown() } }
        manager.openLocalShell()
        manager.splitActivePane(.horizontal)
        manager.splitActivePane(.horizontal)

        let captured = manager.currentWorkspace
        guard case .split(_, _, let saved)? = captured.tabs.first?.root else {
            return XCTFail("expected a split in the snapshot")
        }

        let replayer = SessionManager()
        defer { for s in replayer.sessions { s.shutdown() } }
        replayer.restore(captured.plan { _ in nil })

        guard case .split(_, _, _, let rebuilt)? = replayer.selectedTab?.root else {
            return XCTFail("expected a split after replay")
        }
        XCTAssertEqual(rebuilt, saved, "replay must rebuild the layout that was saved")
    }
}

extension LayoutFidelityTests {
    /// Documents the shape two splits produce, so the rendering question has a
    /// stated baseline to be compared against.
    func testTwoSplitsProduceANestedTreeNotAFlatRow() throws {
        let manager = SessionManager()
        defer { for s in manager.sessions { s.shutdown() } }
        manager.openLocalShell()
        manager.splitActivePane(.horizontal)
        manager.splitActivePane(.horizontal)

        let tab = try XCTUnwrap(manager.selectedTab)
        XCTAssertEqual(tab.leaves.count, 3)
        guard case .split(_, _, let children, let fractions)? = tab.root else {
            return XCTFail("expected a split")
        }
        // Splitting the *active* pane, which is the pane just created, nests
        // rather than widening the row — so the first pane keeps half the
        // width and the later two share the other half.
        XCTAssertEqual(children.count, 2, "shape: \(children.count) children, fractions \(fractions)")
        XCTAssertEqual(fractions, [0.5, 0.5])
    }
}
