import XCTest
@testable import Portside

/// Two actions sharing a default binding is silent: SwiftUI hands the key to
/// one menu item and the other simply never fires, with nothing in the UI to
/// say why. Cheap to guard, expensive to notice by hand.
final class KeyBindingDefaultsTests: XCTestCase {
    func testNoTwoActionsShareADefaultBinding() {
        let actions = ShortcutAction.allCases
        for (i, a) in actions.enumerated() {
            for b in actions[(i + 1)...] {
                XCTAssertNotEqual(a.defaultBinding, b.defaultBinding,
                                  "\(a.label) and \(b.label) both default to \(a.defaultBinding.displaySymbol)")
            }
        }
    }

    func testEveryActionHasALabelAndACategory() {
        for action in ShortcutAction.allCases {
            XCTAssertFalse(action.label.isEmpty)
            XCTAssertTrue(ShortcutAction.categoryOrder.contains(action.category),
                          "\(action.label) is in category \"\(action.category)\", which the settings list won't render")
        }
    }

    /// ⌥⌘M pairs with ⇧⌘M (whole-tab MultiExec) — the shortcut the armed
    /// banner tells you about, so it needs to be the one that's bound.
    func testPaneMultiExecToggleDefaultsToOptionCommandM() {
        XCTAssertEqual(ShortcutAction.togglePaneInMultiExec.defaultBinding.displaySymbol, "⌥⌘M")
    }
}
