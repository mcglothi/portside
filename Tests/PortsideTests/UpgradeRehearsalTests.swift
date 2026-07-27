import Foundation
import XCTest
@testable import Portside

/// Rehearses an upgrade against a real library file.
///
/// 0.16 changes how the library is stored — history moves to a sidecar, legacy
/// history migrates out, recents seed the aggregate. All of that is unit-tested
/// against synthetic fixtures, but synthetic fixtures are written by the same
/// person who wrote the migration and share its blind spots. This one runs
/// against whatever real file you point it at.
///
///     PORTSIDE_UPGRADE_FIXTURE=/path/to/portside.json swift test --filter UpgradeRehearsal
///
/// The fixture is copied first; the original is never opened for writing.
final class UpgradeRehearsalTests: XCTestCase {

    func testRealLibrarySurvivesTheUpgrade() throws {
        guard let fixture = ProcessInfo.processInfo.environment["PORTSIDE_UPGRADE_FIXTURE"] else {
            throw XCTSkip("Set PORTSIDE_UPGRADE_FIXTURE to a real portside.json to run this.")
        }

        let original = try Data(contentsOf: URL(fileURLWithPath: fixture))
        let before = try JSONSerialization.jsonObject(with: original) as? [String: Any] ?? [:]

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-upgrade-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: work) }
        let copy = work.appendingPathComponent("portside.json")
        try original.write(to: copy)

        // First launch on the new build: loads, migrates, writes.
        let upgraded = SessionStore(fileURL: copy)
        XCTAssertNil(upgraded.loadFailure, "a real library must decode")

        func count(_ key: String) -> Int { (before[key] as? [Any])?.count ?? 0 }

        XCTAssertEqual(upgraded.entries.count, count("entries"), "hosts lost")
        XCTAssertEqual(upgraded.macros.count, count("macros"), "macros lost")
        XCTAssertEqual(upgraded.credentialProfiles.count, count("credentialProfiles"),
                       "credential profiles lost — the exact failure the migration bug caused")
        XCTAssertEqual(upgraded.customThemes.count, count("customThemes"), "themes lost")
        XCTAssertEqual(upgraded.forwards.count, count("forwards"), "port forwards lost")
        XCTAssertEqual(upgraded.recents.count, count("recents"), "recents lost")

        if let expected = before["defaultProfileID"] as? String {
            XCTAssertEqual(upgraded.defaultProfileID?.uuidString, expected, "default profile lost")
        }
        // Compare counts, not presence: a saved workspace with no open tabs is
        // a legitimate state, and asserting non-empty reported data loss where
        // there was none.
        let expectedTabs = ((before["workspace"] as? [String: Any])?["tabs"] as? [Any])?.count ?? 0
        XCTAssertEqual(upgraded.workspace.tabs.count, expectedTabs, "saved workspace changed")

        // Recents should have seeded the aggregate so Quick Connect keeps its order.
        XCTAssertEqual(upgraded.connectionStats.count, count("recents"),
                       "every remembered host should carry into the ranking")

        // Second launch: nothing may drift on a plain reload.
        let reloaded = SessionStore(fileURL: copy)
        XCTAssertEqual(reloaded.entries.count, upgraded.entries.count)
        XCTAssertEqual(reloaded.credentialProfiles.count, upgraded.credentialProfiles.count)
        XCTAssertEqual(reloaded.defaultProfileID, upgraded.defaultProfileID)
        XCTAssertEqual(reloaded.connectionStats.count, upgraded.connectionStats.count,
                       "seeding must not run twice")
    }
}
