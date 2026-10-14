import XCTest
@testable import Portside

/// Answering the restore prompt is final for that snapshot.
///
/// Reported from use: choosing Start Fresh and then quitting without opening
/// anything brought the same prompt back at every launch, because the saved
/// snapshot is only rewritten when a tab changes.
@MainActor
final class RestorePromptTests: XCTestCase {
    func testStartFreshForgetsTheLastSession() {
        let manager = SessionManager()
        var saved: WorkspaceSnapshot?
        manager.onWorkspaceChange = { saved = $0 }
        let host = SessionEntry(name: "web", hostname: "web.example.com")
        let last = WorkspaceSnapshot(tabs: [.init(root: .leaf(.init(kind: .host(host.id), includedInMultiExec: true)))])

        manager.bootstrapRestore(snapshot: last, mode: .ask) { $0 == host.id ? host : nil }
        XCTAssertNotNil(manager.pendingRestore, "ask mode offers the restore")

        manager.declineRestore()

        XCTAssertNil(manager.pendingRestore)
        let written = try? XCTUnwrap(saved, "declining must write the snapshot, not leave last time's")
        XCTAssertEqual(written?.isEmpty, true, "nothing is open, so nothing is offered next launch")
    }
}
