import XCTest
@testable import Portside

/// Guards the bulk MultiExec membership rules — above all that no bulk action
/// can sweep a protected host into the broadcast. Protected hosts join only
/// through the per-pane confirmation; a stray "Include All" quietly re-arming
/// prod is exactly the accident the protected flag exists to prevent.
final class MultiExecInclusionTests: XCTestCase {
    func testIncludeAllIncludesEveryOrdinaryPane() {
        for included in [true, false] {
            XCTAssertTrue(MultiExecBulkAction.includeAll.applied(included: included, isProtected: false))
        }
    }

    func testIncludeAllLeavesProtectedHostsAsTheyWere() {
        XCTAssertFalse(MultiExecBulkAction.includeAll.applied(included: false, isProtected: true),
                       "Include All must not pull a protected host into the broadcast")
        XCTAssertTrue(MultiExecBulkAction.includeAll.applied(included: true, isProtected: true),
                      "a protected host already confirmed in stays in")
    }

    func testExcludeAllClearsEveryPaneIncludingProtected() {
        for isProtected in [true, false] {
            XCTAssertFalse(MultiExecBulkAction.excludeAll.applied(included: true, isProtected: isProtected))
        }
    }

    func testInvertFlipsOrdinaryPanes() {
        XCTAssertFalse(MultiExecBulkAction.invert.applied(included: true, isProtected: false))
        XCTAssertTrue(MultiExecBulkAction.invert.applied(included: false, isProtected: false))
    }

    func testInvertNeverTurnsAProtectedHostOn() {
        XCTAssertFalse(MultiExecBulkAction.invert.applied(included: false, isProtected: true),
                       "inverting must not be a back door into a protected host")
        XCTAssertFalse(MultiExecBulkAction.invert.applied(included: true, isProtected: true),
                       "an included protected host still inverts out")
    }

    /// The workflow from the feature request: exclude two boxes, run the
    /// command, put them back — the round trip must land where it started.
    func testExcludeThenIncludeAllRoundTripsOrdinaryPanes() {
        var included = true
        included = MultiExecBulkAction.excludeAll.applied(included: included, isProtected: false)
        XCTAssertFalse(included)
        included = MultiExecBulkAction.includeAll.applied(included: included, isProtected: false)
        XCTAssertTrue(included)
    }

    func testEveryBulkActionHasALabelAndHelp() {
        for action in MultiExecBulkAction.allCases {
            XCTAssertFalse(action.label.isEmpty)
            XCTAssertFalse(action.help.isEmpty)
        }
    }

    /// The banner greys a button out when its action is a no-op, and asks the
    /// action itself rather than counting included panes. A tab whose only
    /// excluded pane is protected must therefore read as "nothing to include" —
    /// counting would leave Include All enabled and inert.
    func testIncludeAllIsANoOpWhenTheOnlyExclusionIsProtected() {
        let panes = [(included: true, isProtected: false), (included: false, isProtected: true)]
        XCTAssertFalse(changesAnything(.includeAll, panes),
                       "Include All can't touch a protected host, so it would change nothing here")
        XCTAssertTrue(changesAnything(.excludeAll, panes))
        XCTAssertTrue(changesAnything(.invert, panes), "the ordinary included pane still inverts out")
    }

    func testBulkActionsAreNoOpsAtTheirFixedPoints() {
        XCTAssertFalse(changesAnything(.includeAll, [(true, false), (true, false)]))
        XCTAssertFalse(changesAnything(.excludeAll, [(false, false), (false, true)]))
    }

    /// Each bulk action needs its own shortcut slot. Two sharing one would make
    /// a single key run whichever menu item SwiftUI resolved first, silently.
    func testEachBulkActionHasItsOwnShortcutAction() {
        let actions = MultiExecBulkAction.allCases.map(\.shortcutAction)
        XCTAssertEqual(Set(actions).count, MultiExecBulkAction.allCases.count)
    }

    /// The shortcut settings row and the menu item must read the same, or
    /// rebinding "Invert Selection" means hunting for it under another name.
    func testShortcutLabelsMatchTheActionLabels() {
        for action in MultiExecBulkAction.allCases {
            XCTAssertEqual(action.shortcutAction.label, action.label)
        }
    }

    // MARK: - Focus after a bulk action

    /// The reported bug: Invert Selection excluded the focused pane, focus
    /// stayed put, and the next command went to that one host instead of the
    /// group — `mirrorUserInput` won't mirror *from* an excluded pane, but
    /// SwiftTerm still writes to its own pty.
    func testFocusMovesOffAPaneABulkActionExcluded() {
        let a = UUID(), b = UUID(), c = UUID()
        let afterInvert = [(id: a, included: false), (id: b, included: true), (id: c, included: false)]
        XCTAssertEqual(MultiExecFocus.refocused(from: a, panes: afterInvert), b,
                       "focus must land on the first pane still in the broadcast")
    }

    func testFocusStaysWhenTheFocusedPaneIsStillIncluded() {
        let a = UUID(), b = UUID()
        XCTAssertNil(MultiExecFocus.refocused(from: a, panes: [(a, true), (b, false)]),
                     "nothing to fix — don't yank the caret out of a pane that's still broadcasting")
    }

    /// Exclude All has nowhere better to put focus, and its 0-of-N banner is
    /// its own warning. Moving focus anyway would be arbitrary.
    func testFocusStaysWhenNothingIsIncluded() {
        let a = UUID(), b = UUID()
        XCTAssertNil(MultiExecFocus.refocused(from: a, panes: [(a, false), (b, false)]))
    }

    func testFocusPicksTheFirstIncludedPaneInOrder() {
        let a = UUID(), b = UUID(), c = UUID()
        XCTAssertEqual(MultiExecFocus.refocused(from: a, panes: [(a, false), (b, true), (c, true)]), b)
    }

    func testNoFocusChangeWithoutAFocusedPaneOrAStaleID() {
        let a = UUID()
        XCTAssertNil(MultiExecFocus.refocused(from: nil, panes: [(a, true)]))
        XCTAssertNil(MultiExecFocus.refocused(from: UUID(), panes: [(a, true)]),
                     "a focus id that isn't in this tab must not silently retarget")
    }

    /// Mirrors `SessionManager.wouldChangeAnything` over plain pairs.
    private func changesAnything(_ action: MultiExecBulkAction,
                                 _ panes: [(included: Bool, isProtected: Bool)]) -> Bool {
        panes.contains { action.applied(included: $0.included, isProtected: $0.isProtected) != $0.included }
    }
}
