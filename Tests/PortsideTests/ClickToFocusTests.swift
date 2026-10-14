import XCTest
import AppKit
@testable import Portside

/// Clicking a pane gives it the keyboard, not just the focus ring.
///
/// Reported from the 0.38 beta (#76): with Metal on, SwiftTerm 2 covers the
/// terminal with a surface view that doesn't accept first responder, so
/// AppKit never moved the keyboard on a click. The pane you clicked turned
/// active while typing kept going to the newest pane. Portside's click
/// handler has to hand over the keyboard itself.
@MainActor
final class ClickToFocusTests: XCTestCase {
    func testClickingAPaneMakesItTheFirstResponder() throws {
        let manager = SessionManager()
        defer { for s in manager.sessions { s.shutdown() } }
        manager.openLocalShell()
        manager.splitActivePane(.horizontal)
        let tab = try XCTUnwrap(manager.selectedTab)
        let (first, second) = (tab.leaves[0], tab.leaves[1])

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        first.terminalView.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        second.terminalView.frame = NSRect(x: 400, y: 0, width: 400, height: 400)
        container.addSubview(first.terminalView)
        container.addSubview(second.terminalView)
        window.contentView = container

        // The newest pane has the keyboard, as it does after a grid opens.
        tab.activePaneID = second.id
        window.makeFirstResponder(second.terminalView)

        let click = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 200, y: 200), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        manager.focusClickedPane(click)

        XCTAssertEqual(tab.activePaneID, first.id, "the clicked pane is active")
        XCTAssertTrue(window.firstResponder === first.terminalView,
                      "and has the keyboard: \(String(describing: window.firstResponder))")

        // Clicking the already-active pane still hands it the keyboard: a
        // pane can be active without having it, which was the beta's state.
        window.makeFirstResponder(second.terminalView)
        manager.focusClickedPane(click)
        XCTAssertTrue(window.firstResponder === first.terminalView)
    }
}
