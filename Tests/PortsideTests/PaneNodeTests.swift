import XCTest
@testable import Portside

/// The pane-tree algebra (split / remove / collapse / normalize), tested with a
/// lightweight stub leaf so no terminals are spawned.
final class PaneNodeTests: XCTestCase {

    private struct StubLeaf: Identifiable { let id = UUID() }
    private typealias Node = PaneNode<StubLeaf>

    private func leaf() -> (node: Node, id: UUID) {
        let stub = StubLeaf()
        return (.leaf(stub), stub.id)
    }

    // MARK: - leaves

    func testLeavesInOrder() {
        let (a, aID) = leaf(), (b, bID) = leaf(), (c, cID) = leaf()
        let tree = Node.split(id: UUID(), orientation: .horizontal,
                              children: [a, .split(id: UUID(), orientation: .vertical,
                                                   children: [b, c])])
        XCTAssertEqual(tree.leaves.map(\.id), [aID, bID, cID])
    }

    // MARK: - splitting

    func testSplittingLeafBecomesTwoWaySplit() {
        let (a, aID) = leaf(), (b, _) = leaf()
        let split = a.splitting(leafID: aID, with: b, orientation: .horizontal)

        guard case .split(_, let orientation, let children) = split else {
            return XCTFail("expected a split")
        }
        XCTAssertEqual(orientation, .horizontal)
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(split.leaves.count, 2)
    }

    func testSplittingOnlyAffectsTargetLeaf() {
        let (a, aID) = leaf(), (b, bID) = leaf(), (c, _) = leaf()
        let tree = Node.split(id: UUID(), orientation: .horizontal,
                              children: [a, b])
        let result = tree.splitting(leafID: bID, with: c, orientation: .vertical)

        // a untouched; b replaced by a vertical 2-split → 3 leaves total.
        XCTAssertEqual(result.leaves.count, 3)
        XCTAssertEqual(result.leaves.first?.id, aID)
    }

    // MARK: - replacingLeaf

    func testReplacingLeafSwapsInPlace() {
        let (a, aID) = leaf(), (b, bID) = leaf()
        let replacement = StubLeaf()
        let tree = Node.split(id: UUID(), orientation: .horizontal,
                              children: [a, b])
        let result = tree.replacingLeaf(aID, with: replacement)

        // Same geometry, a swapped for the replacement, b untouched.
        guard case .split(_, _, let children) = result else {
            return XCTFail("expected the split shape to be preserved")
        }
        XCTAssertEqual(result.leaves.map(\.id), [replacement.id, bID])
        XCTAssertNotEqual(replacement.id, aID)
    }

    func testReplacingUnknownLeafIsNoOp() {
        let (a, aID) = leaf()
        let result = a.replacingLeaf(UUID(), with: StubLeaf())
        XCTAssertEqual(result.leaves.map(\.id), [aID])
    }

    // MARK: - removingLeaf + collapse

    func testRemovingSoleLeafReturnsNil() {
        let (a, aID) = leaf()
        XCTAssertNil(a.removingLeaf(aID))
    }

    func testRemovingUnknownLeafIsNoOp() {
        let (a, _) = leaf()
        XCTAssertNotNil(a.removingLeaf(UUID()))
    }

    func testRemovingOneChildCollapsesSplitToSibling() {
        let (a, aID) = leaf(), (b, bID) = leaf()
        let tree = Node.split(id: UUID(), orientation: .horizontal,
                              children: [a, b])
        let result = tree.removingLeaf(aID)

        // The split collapses to the surviving leaf b.
        guard case .leaf(let survivor)? = result else {
            return XCTFail("expected the split to collapse to a leaf")
        }
        XCTAssertEqual(survivor.id, bID)
    }

    func testRemovingFromThreeWayKeepsSplitAndRenormalizes() {
        let (a, _) = leaf(), (b, bID) = leaf(), (c, _) = leaf()
        let tree = Node.split(id: UUID(), orientation: .vertical,
                              children: [a, b, c])
        let result = tree.removingLeaf(bID)

        guard case .split(_, _, let children)? = result else {
            return XCTFail("expected a split of the two survivors")
        }
        XCTAssertEqual(children.count, 2, "the two survivors stay, in order")
    }

    func testRemovingNestedLeafCollapsesInnerSplit() {
        let (a, _) = leaf(), (b, bID) = leaf(), (c, cID) = leaf()
        // outer[ a | inner[ b / c ] ]
        let inner = Node.split(id: UUID(), orientation: .vertical, children: [b, c])
        let outer = Node.split(id: UUID(), orientation: .horizontal, children: [a, inner])

        let result = outer.removingLeaf(bID)
        // inner collapses to c, so outer becomes [ a | c ] — still 2 leaves.
        XCTAssertEqual(result?.leaves.count, 2)
        XCTAssertEqual(result?.leaves.last?.id, cID)
    }
    // MARK: - swappingLeaves

    /// The whole point: two panes trade places and nothing else moves.
    func testSwappingTwoPanesExchangesTheirPositions() {
        let (a, aID) = leaf(), (b, bID) = leaf(), (c, cID) = leaf(), (d, dID) = leaf()
        let grid = Node.split(id: UUID(), orientation: .vertical, children: [
            .split(id: UUID(), orientation: .horizontal, children: [a, b]),
            .split(id: UUID(), orientation: .horizontal, children: [c, d]),
        ])

        let swapped = grid.swappingLeaves(aID, dID)

        XCTAssertEqual(swapped.leaves.map(\.id), [dID, bID, cID, aID])
    }

    /// Composing two `replacingLeaf` calls looks like a swap and isn't: after
    /// the first, the tree holds two leaves with the same id and the second
    /// overwrites both — one session in two cells, the other gone.
    func testSwappingDoesNotDuplicateOneSideOverTheOther() {
        let (a, aID) = leaf(), (b, bID) = leaf()
        let pair = Node.split(id: UUID(), orientation: .horizontal, children: [a, b])

        let swapped = pair.swappingLeaves(aID, bID)

        XCTAssertEqual(Set(swapped.leaves.map(\.id)), Set([aID, bID]),
                       "both panes must survive the swap")
        XCTAssertEqual(swapped.leaves.map(\.id), [bID, aID])
    }

    /// The fix for the crash. HSplitView can't have its arranged subviews
    /// reordered underneath it, so a split whose children changed places has to
    /// come back as a *different* split for SwiftUI to rebuild rather than
    /// rearrange. Without this, swapping two panes in a two-pane tab threw from
    /// AppKit's layout pass — and short of that, left one pane a sliver.
    func testARearrangedSplitGetsANewIdentity() {
        let (a, aID) = leaf(), (b, bID) = leaf()
        let pair = Node.split(id: UUID(), orientation: .horizontal, children: [a, b])

        let swapped = pair.swappingLeaves(aID, bID)

        XCTAssertNotEqual(swapped.id, pair.id)
    }

    /// A new id has to reach the root. Giving a split a fresh id changes its
    /// *parent's* child identities, which is the same arranged-subview mutation
    /// one level up — so an ancestor that kept its id would sit there
    /// rearranging a live split view.
    ///
    /// This test previously asserted the opposite, and was wrong: it encoded the
    /// belief that only the split directly holding the swapped panes mattered.
    /// A five-pane grid proved otherwise in the field — see below.
    func testANewIdentityReachesTheRoot() {
        let (a, aID) = leaf(), (b, bID) = leaf(), (c, _) = leaf(), (d, _) = leaf()
        let topRow: Node = .split(id: UUID(), orientation: .horizontal, children: [a, b])
        let bottomRow: Node = .split(id: UUID(), orientation: .horizontal, children: [c, d])
        let grid = Node.split(id: UUID(), orientation: .vertical, children: [topRow, bottomRow])

        let swapped = grid.swappingLeaves(aID, bID)

        XCTAssertNotEqual(swapped.id, grid.id, "the root holds a rebuilt child, so it is rebuilt too")
        guard case .split(_, _, let rows) = swapped else { return XCTFail("expected a split") }
        XCTAssertNotEqual(rows[0].id, topRow.id, "the row that was rearranged")
        XCTAssertEqual(rows[1].id, bottomRow.id, "the row that wasn't keeps its identity")
    }

    /// The five-host grid that found this. `gridTree` lays 5 panes out as
    /// ceil(sqrt(5)) = 3 columns, so a vertical root over rows of 3 and 2.
    /// Swapping within the first row rebuilt that row and left the root
    /// reordering its two children — which turned a horizontal resize into a
    /// vertical one rather than fixing it.
    func testAFivePaneGridRebuildsFromTheRootOnAnySwap() {
        let leaves = (0..<5).map { _ in leaf() }
        let topRow: Node = .split(id: UUID(), orientation: .horizontal,
                                  children: leaves[0...2].map(\.node))
        let bottomRow: Node = .split(id: UUID(), orientation: .horizontal,
                                     children: leaves[3...4].map(\.node))
        let grid = Node.split(id: UUID(), orientation: .vertical, children: [topRow, bottomRow])

        // Within the top row — the case that still resized after the first fix.
        let sameRow = grid.swappingLeaves(leaves[0].id, leaves[1].id)
        XCTAssertNotEqual(sameRow.id, grid.id)

        // And across rows, which has to hold too.
        let acrossRows = grid.swappingLeaves(leaves[0].id, leaves[4].id)
        XCTAssertNotEqual(acrossRows.id, grid.id)
        XCTAssertEqual(acrossRows.leaves.map(\.id),
                       [leaves[4].id, leaves[1].id, leaves[2].id, leaves[3].id, leaves[0].id])
    }

    func testSwappingIsReversible() {
        let (a, aID) = leaf(), (b, bID) = leaf(), (c, _) = leaf()
        let tree = Node.split(id: UUID(), orientation: .horizontal, children: [a, b, c])

        let there = tree.swappingLeaves(aID, bID)
        let back = there.swappingLeaves(aID, bID)

        XCTAssertEqual(back.leaves.map(\.id), tree.leaves.map(\.id))
    }

    /// Dropping a pane on itself must not rebuild the tree — a new split id
    /// would churn SwiftUI's identity for no reason.
    func testSwappingAPaneWithItselfIsANoOp() {
        let (a, aID) = leaf(), (b, _) = leaf()
        let tree = Node.split(id: UUID(), orientation: .horizontal, children: [a, b])

        XCTAssertEqual(tree.swappingLeaves(aID, aID).id, tree.id)
    }

    func testSwappingWithAPaneThatIsNotHereLeavesTheTreeAlone() {
        let (a, aID) = leaf(), (b, bID) = leaf()
        let tree = Node.split(id: UUID(), orientation: .horizontal, children: [a, b])

        let untouched = tree.swappingLeaves(aID, UUID())

        XCTAssertEqual(untouched.leaves.map(\.id), [aID, bID])
    }

    /// Swap is defined on hand-split layouts too, where "insert between these
    /// two" would have no unambiguous answer.
    func testSwappingAcrossUnevenSplitsKeepsTheGeometry() {
        let (a, aID) = leaf(), (b, bID) = leaf(), (c, cID) = leaf()
        // One tall pane beside a stack of two.
        let stack: Node = .split(id: UUID(), orientation: .vertical, children: [b, c])
        let tree = Node.split(id: UUID(), orientation: .horizontal, children: [a, stack])

        let swapped: Node = tree.swappingLeaves(aID, cID)

        XCTAssertEqual(swapped.leaves.map(\.id), [cID, bID, aID])
        // The shape is untouched — only the occupants changed.
        guard case .split(_, .horizontal, let children) = swapped,
              case .split(_, .vertical, let stacked) = children[1] else {
            return XCTFail("the split structure should survive a swap")
        }
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(stacked.count, 2)
    }

}
