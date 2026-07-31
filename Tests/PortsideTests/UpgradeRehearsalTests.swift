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

        XCTAssertEqual(upgraded.terminal.scrollbackLines,
                       (before["terminal"] as? [String: Any])?["scrollbackLines"] as? Int
                           ?? TerminalSettings().scrollbackLines,
                       "terminal settings lost in the local split")

        // Second launch: nothing may drift on a plain reload.
        let reloaded = SessionStore(fileURL: copy)
        XCTAssertEqual(reloaded.entries.count, upgraded.entries.count)
        XCTAssertEqual(reloaded.credentialProfiles.count, upgraded.credentialProfiles.count)
        XCTAssertEqual(reloaded.defaultProfileID, upgraded.defaultProfileID)
        XCTAssertEqual(reloaded.connectionStats.count, upgraded.connectionStats.count,
                       "seeding must not run twice")

        // The local split, on a real file. Everything machine-shaped has to
        // survive the move and then stay put — a migration that re-runs on
        // every launch would keep rewriting the library it was meant to leave
        // alone.
        XCTAssertEqual(reloaded.workspace, upgraded.workspace, "workspace drifted after the split")
        XCTAssertEqual(reloaded.recents.count, upgraded.recents.count, "recents drifted")
        XCTAssertEqual(reloaded.customThemes.count, upgraded.customThemes.count, "themes drifted")
        XCTAssertEqual(reloaded.terminal, upgraded.terminal, "terminal settings drifted")
        XCTAssertEqual(reloaded.appearance, upgraded.appearance, "appearance drifted")

        let localURL = copy.deletingPathExtension().appendingPathExtension("local.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: localURL.path),
                      "local state should have its own file after the upgrade")

        let library = try JSONSerialization.jsonObject(
            with: Data(contentsOf: copy)) as? [String: Any] ?? [:]
        for moved in ["workspace", "recents", "appearance", "customThemes", "terminal", "logging"] {
            XCTAssertNil(library[moved],
                         "\(moved) should no longer be written into the library")
        }
        XCTAssertNotNil(library["entries"], "the hosts must obviously stay")
    }
}

/// Rehearses an *export* round trip against a real exported file.
///
///     PORTSIDE_EXPORT_FIXTURE=/path/to/portside-sessions.json \
///       PORTSIDE_LIBRARY_FIXTURE=/path/to/portside.json \
///       swift test --filter ExportRehearsal
///
/// Both fixtures are read-only; everything happens in a temp directory.
final class ExportRehearsalTests: XCTestCase {

    func testARealExportRoundTripsWithItsCredentialProfiles() throws {
        guard let exportPath = ProcessInfo.processInfo.environment["PORTSIDE_EXPORT_FIXTURE"],
              let libraryPath = ProcessInfo.processInfo.environment["PORTSIDE_LIBRARY_FIXTURE"] else {
            throw XCTSkip("Set PORTSIDE_EXPORT_FIXTURE and PORTSIDE_LIBRARY_FIXTURE to run this.")
        }

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: work) }

        // The source machine, loaded from its real library.
        let source = SessionStore(fileURL: work.appendingPathComponent("source.json"))
        try Data(contentsOf: URL(fileURLWithPath: libraryPath))
            .write(to: work.appendingPathComponent("source.json"))
        let reloadedSource = SessionStore(fileURL: work.appendingPathComponent("source.json"))
        _ = source
        XCTAssertFalse(reloadedSource.credentialProfiles.isEmpty, "fixture should have profiles")

        // An export written by the *old* build: no profiles at all.
        let oldExport = try XCTUnwrap(
            LibraryTransfer.decode(Data(contentsOf: URL(fileURLWithPath: exportPath))))
        XCTAssertNil(oldExport.credentialProfiles, "fixture should predate profiles travelling")

        let referencing = (oldExport.entries ?? []).filter { $0.credentialProfileID != nil }.count
        XCTAssertGreaterThan(referencing, 0, "fixture should exercise the bug")

        // Importing it fresh: every dangling reference is cleared rather than
        // left pointing at nothing or falling through to this Mac's default.
        let oldTarget = SessionStore(fileURL: work.appendingPathComponent("old-target.json"))
        oldTarget.importExport(entries: oldExport.entries ?? [], folders: oldExport.folders ?? [],
                               macros: oldExport.macros ?? [],
                               credentialProfiles: oldExport.credentialProfiles ?? [])
        XCTAssertTrue(oldTarget.entries.allSatisfy { $0.credentialProfileID == nil },
                      "a profile that isn't here must not be left dangling")
        XCTAssertTrue(oldTarget.entries.allSatisfy { !$0.savePassword },
                      "and must not fall through to this machine's credentials")

        // Re-exported by the new build, the profiles travel...
        let newExport = try LibraryTransfer.encodeSessions(
            entries: reloadedSource.entries, folders: reloadedSource.explicitFolders,
            credentialProfiles: reloadedSource.credentialProfiles)
        let decoded = try XCTUnwrap(LibraryTransfer.decode(newExport))
        XCTAssertEqual(decoded.credentialProfiles?.count, reloadedSource.credentialProfiles.count)

        // ...and the references survive the trip.
        let newTarget = SessionStore(fileURL: work.appendingPathComponent("new-target.json"))
        newTarget.importExport(entries: decoded.entries ?? [], folders: decoded.folders ?? [],
                               macros: decoded.macros ?? [],
                               credentialProfiles: decoded.credentialProfiles ?? [])
        let landed = newTarget.entries.filter { $0.credentialProfileID != nil }.count
        let expected = reloadedSource.entries.filter { $0.credentialProfileID != nil }.count
        XCTAssertEqual(landed, expected, "every profile reference should survive the round trip")
        XCTAssertTrue(landed > 0)
    }
}
