import XCTest
@testable import Portside

/// Gate 5 for the fields added after 0.34: a library and agent settings
/// written by 0.34 — which has none of them — load with the meaning they
/// had then. (Going back is safe the other way round: every decoder here
/// ignores keys it doesn't know.)
final class UpgradeFrom034Tests: XCTestCase {
    func testA034SourceIsOn() throws {
        let json = #"{"id":"5E0C4C1E-9B3A-4F7E-9E2B-1A2B3C4D5E6F","name":"Team","remote":"/srv/inv.git","ref":"main","path":"portside.json"}"#
        let source = try JSONDecoder().decode(InventorySource.self, from: Data(json.utf8))
        XCTAssertTrue(source.isEnabled, "every 0.34 source was on")
    }

    func testA034OverlayHasNoSourceYet() throws {
        let json = #"{"entryID":"5E0C4C1E-9B3A-4F7E-9E2B-1A2B3C4D5E6F","isFavorite":true}"#
        let overlay = try JSONDecoder().decode(SharedOverlay.self, from: Data(json.utf8))
        XCTAssertNil(overlay.sourceID)
        XCTAssertTrue(overlay.isFavorite)
        XCTAssertFalse(overlay.isEmpty)
    }

    /// 0.34 approvals carry no `canType`: a program approved for typing keeps
    /// it; one approved for editing was never asked about typing, so it
    /// doesn't get it now.
    @MainActor
    func testA034ApprovalKeepsWhatItWasAskedFor() throws {
        let json = #"""
        {"enabled":true,"connectCap":5,"allowInput":true,"allowEdit":true,
         "approvals":[{"name":"claude","path":"/x/claude","tier":3,"approvedAt":"2026-10-08T12:00:00Z"},
                      {"name":"codex","path":"/x/codex","tier":4,"approvedAt":"2026-10-08T12:00:00Z"}]}
        """#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let settings = try decoder.decode(AgentController.Settings.self, from: Data(json.utf8))
        let claude = try XCTUnwrap(settings.approvals.first { $0.name == "claude" })
        let codex = try XCTUnwrap(settings.approvals.first { $0.name == "codex" })
        XCTAssertTrue(claude.covers(.input))
        XCTAssertFalse(codex.covers(.input), "edit never implied typing")
        XCTAssertTrue(codex.covers(.edit))
        XCTAssertEqual(codex.label, "Read, open and edit")
    }
}
