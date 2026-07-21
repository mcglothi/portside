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
                                                   children: [b, c], fractions: [0.5, 0.5])],
                              fractions: [0.5, 0.5])
        XCTAssertEqual(tree.leaves.map(\.id), [aID, bID, cID])
    }

    // MARK: - splitting

    func testSplittingLeafBecomesTwoWaySplit() {
        let (a, aID) = leaf(), (b, _) = leaf()
        let split = a.splitting(leafID: aID, with: b, orientation: .horizontal)

        guard case .split(_, let orientation, let children, let fractions) = split else {
            return XCTFail("expected a split")
        }
        XCTAssertEqual(orientation, .horizontal)
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(fractions, [0.5, 0.5])
        XCTAssertEqual(split.leaves.count, 2)
    }

    func testSplittingOnlyAffectsTargetLeaf() {
        let (a, aID) = leaf(), (b, bID) = leaf(), (c, _) = leaf()
        let tree = Node.split(id: UUID(), orientation: .horizontal,
                              children: [a, b], fractions: [0.5, 0.5])
        let result = tree.splitting(leafID: bID, with: c, orientation: .vertical)

        // a untouched; b replaced by a vertical 2-split → 3 leaves total.
        XCTAssertEqual(result.leaves.count, 3)
        XCTAssertEqual(result.leaves.first?.id, aID)
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
                              children: [a, b], fractions: [0.3, 0.7])
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
                              children: [a, b, c], fractions: [0.2, 0.3, 0.5])
        let result = tree.removingLeaf(bID)

        guard case .split(_, _, let children, let fractions)? = result else {
            return XCTFail("expected a split of the two survivors")
        }
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(fractions.reduce(0, +), 1.0, accuracy: 0.0001)
        // Original 0.2 : 0.5 renormalized to sum 1 while keeping their ratio.
        XCTAssertEqual(fractions[0], 0.2 / 0.7, accuracy: 0.0001)
        XCTAssertEqual(fractions[1], 0.5 / 0.7, accuracy: 0.0001)
    }

    func testRemovingNestedLeafCollapsesInnerSplit() {
        let (a, _) = leaf(), (b, bID) = leaf(), (c, cID) = leaf()
        // outer[ a | inner[ b / c ] ]
        let inner = Node.split(id: UUID(), orientation: .vertical, children: [b, c], fractions: [0.5, 0.5])
        let outer = Node.split(id: UUID(), orientation: .horizontal, children: [a, inner], fractions: [0.5, 0.5])

        let result = outer.removingLeaf(bID)
        // inner collapses to c, so outer becomes [ a | c ] — still 2 leaves.
        XCTAssertEqual(result?.leaves.count, 2)
        XCTAssertEqual(result?.leaves.last?.id, cID)
    }

    // MARK: - normalized

    func testNormalizedSumsToOne() {
        XCTAssertEqual(normalizedFractions([1, 1, 2]).reduce(0, +), 1.0, accuracy: 0.0001)
    }

    func testNormalizedZeroTotalFallsBackToEqual() {
        let result = normalizedFractions([0, 0])
        XCTAssertEqual(result, [0.5, 0.5])
    }
}
