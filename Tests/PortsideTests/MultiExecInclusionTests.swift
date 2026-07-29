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

    /// Mirrors `SessionManager.wouldChangeAnything` over plain pairs.
    private func changesAnything(_ action: MultiExecBulkAction,
                                 _ panes: [(included: Bool, isProtected: Bool)]) -> Bool {
        panes.contains { action.applied(included: $0.included, isProtected: $0.isProtected) != $0.included }
    }
}
