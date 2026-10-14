import AppKit
import SwiftTerm
import XCTest
@testable import Portside

/// Portside owns the view that runs the pty (#69). SwiftTerm v2's
/// `LocalProcessTerminalView` feeds output straight to its renderer and never
/// calls `dataReceived`, and every byte-level feature hangs off that call:
/// logs, command capture, the timeline, the input guard.
@MainActor
final class ProcessTerminalViewTests: XCTestCase {
    func testTheSessionViewIsPortsidesOwnNotSwiftTerms() {
        let view = LoggingTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertTrue(view is ProcessTerminalView)
        XCTAssertFalse((view as NSView) is LocalProcessTerminalView,
                       "back on SwiftTerm's process view, whose byte hook v2 no longer calls")
    }

    /// A real process's output reaches the hook Portside overrides.
    func testProcessOutputReachesDataReceived() async throws {
        final class Spy: ProcessTerminalView {
            var seen = Data()
            override func dataReceived(slice: ArraySlice<UInt8>) {
                seen.append(contentsOf: slice)
                super.dataReceived(slice: slice)
            }
        }
        let view = Spy(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.startProcess(executable: "/bin/sh", args: ["-c", "printf portside-tap"])
        for _ in 0..<100 where !String(decoding: view.seen, as: UTF8.self).contains("portside-tap") {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(String(decoding: view.seen, as: UTF8.self).contains("portside-tap"))
    }
}
