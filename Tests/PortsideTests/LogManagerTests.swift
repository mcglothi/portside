import Foundation
import XCTest
@testable import Portside

/// The transcript folder in Settings ▸ Recording is user-chosen and can be an
/// *existing* directory — Documents, a git checkout, a whole home folder.
/// Maintenance used to recursively gzip every `.log` under it purely by
/// extension, and search read every `.log`/`.log.gz` the same way. These
/// confirm the fix: only files matching what `makeLogger` itself generates,
/// directly inside a host subdirectory, are ever touched.
final class LogManagerTests: XCTestCase {

    // MARK: - Filename ownership

    func testOwnedFilenamesMatchWhatMakeLoggerGenerates() {
        XCTAssertTrue(LogManager.isOwnedLogFilename("web-01_2026-07-27_10-05-30.log"))
        XCTAssertTrue(LogManager.isOwnedLogFilename("web-01_2026-07-27_10-05-30-2.log"))
        XCTAssertTrue(LogManager.isOwnedLogFilename("web-01_2026-07-27_10-05-30.log.gz"))
        // Hostnames can themselves contain underscores (hostKey's sanitizer
        // allows them); the pattern must still find the timestamp suffix.
        XCTAssertTrue(LogManager.isOwnedLogFilename("my_host_2026-07-27_10-05-30.log"))
    }

    func testArbitraryDotLogFilesAreNotOwned() {
        // Exactly the audit's scenario: a directory of someone else's logs
        // selected (deliberately or not) as the transcript folder.
        XCTAssertFalse(LogManager.isOwnedLogFilename("system.log"))
        XCTAssertFalse(LogManager.isOwnedLogFilename("access.log"))
        XCTAssertFalse(LogManager.isOwnedLogFilename("error.log.gz"))
        XCTAssertFalse(LogManager.isOwnedLogFilename("README.md"))
        XCTAssertFalse(LogManager.isOwnedLogFilename(""))
    }

    // MARK: - Maintenance scope

    func testMaintenanceOnlyCompressesOwnedFilesInHostSubdirectories() throws {
        let base = try tempDirectory()
        let hostDir = base.appendingPathComponent("web-01")
        try FileManager.default.createDirectory(at: hostDir, withIntermediateDirectories: true)

        let owned = hostDir.appendingPathComponent("web-01_2020-01-01_00-00-00.log")
        try "session transcript".write(to: owned, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -365 * 86_400)], ofItemAtPath: owned.path
        )

        // A foreign .log directly in the base (not inside a host directory)
        // and one inside the host directory that doesn't match our naming —
        // both equally old, both must survive untouched.
        let foreignInBase = base.appendingPathComponent("system.log")
        try "not ours".write(to: foreignInBase, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -365 * 86_400)], ofItemAtPath: foreignInBase.path
        )
        let foreignInHostDir = hostDir.appendingPathComponent("notes.log")
        try "not ours either".write(to: foreignInHostDir, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -365 * 86_400)], ofItemAtPath: foreignInHostDir.path
        )

        var settings = LoggingSettings()
        settings.directoryPath = base.path
        settings.compressAfterDays = 1

        LogManager.runMaintenance(settings: settings)
        // Maintenance dispatches to a background queue; give it a moment.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, FileManager.default.fileExists(atPath: owned.path) {
            Thread.sleep(forTimeInterval: 0.05)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path),
                       "the owned log should have been compressed (and thus removed)")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: hostDir.appendingPathComponent("web-01_2020-01-01_00-00-00.log.gz").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreignInBase.path),
                     "a foreign .log directly in the base directory must be untouched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreignInHostDir.path),
                     "a non-matching .log inside a host directory must be untouched")
    }

    // MARK: - Search scope

    func testSearchOnlyReadsOwnedFilesEvenWhenNamesCollideOnExtension() throws {
        let base = try tempDirectory()
        let hostDir = base.appendingPathComponent("web-01")
        try FileManager.default.createDirectory(at: hostDir, withIntermediateDirectories: true)

        try "needle in the owned file".write(
            to: hostDir.appendingPathComponent("web-01_2026-07-27_10-05-30.log"),
            atomically: true, encoding: .utf8
        )
        try "needle in a foreign file".write(
            to: base.appendingPathComponent("other.log"), atomically: true, encoding: .utf8
        )
        try "needle in a foreign file inside the host dir".write(
            to: hostDir.appendingPathComponent("other.log"), atomically: true, encoding: .utf8
        )

        var settings = LoggingSettings()
        settings.directoryPath = base.path

        let matches = LogManager.search("needle", settings: settings)
        XCTAssertEqual(matches.count, 1, "only the owned file should have been searched")
        XCTAssertEqual(matches.first?.line, "needle in the owned file")
    }

    private func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-logmanager-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }
}
