import XCTest
@testable import Portside

/// The stale-read guard: `save()` writes the whole library, so a save made
/// against a copy that has since changed on disk discards the change with no
/// trace. Matters more now `PORTSIDE_LIBRARY_DIR` can put the library in a
/// synced folder, where two machines really can hold it at once.
final class ExternalChangeTests: XCTestCase {
    private var tempURL: URL!

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-ext-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        try? FileManager.default.removeItem(
            at: tempURL.deletingPathExtension().appendingPathExtension("history.json"))
        super.tearDown()
    }

    private func host(_ name: String) -> SessionEntry {
        SessionEntry(name: name, folder: "", hostname: "\(name).example.com")
    }

    /// Rewrites the file behind the store's back, the way another Portside or
    /// a sync client would. Nudges the date because a same-second write can
    /// otherwise land on the identical timestamp.
    private func writeBehindItsBack(_ names: [String]) throws {
        // Both `entries` and `macros` are non-optional in the document, so a
        // partial object would quarantine rather than load — which would test
        // the wrong thing.
        let entries = try String(
            data: JSONEncoder().encode(names.map(host)), encoding: .utf8)!
        let json = "{\"entries\":\(entries),\"macros\":[]}"
        try json.write(to: tempURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: tempURL.path)
    }

    func testOurOwnRepeatedSavesAreNotMistakenForAConflict() throws {
        // Every atomic write replaces the file and moves its date on, so a
        // guard comparing against anything but our own last write would refuse
        // to save a second time.
        let store = SessionStore(fileURL: tempURL)
        for i in 0..<5 { store.upsert(host("web-\(i)")) }

        XCTAssertFalse(store.externalChange)
        XCTAssertEqual(store.entries.count, 5)
        XCTAssertEqual(SessionStore(fileURL: tempURL).entries.count, 5, "all five reached disk")
    }

    func testAChangeOnDiskBlocksTheNextSave() throws {
        let store = SessionStore(fileURL: tempURL)
        store.upsert(host("mine"))

        try writeBehindItsBack(["theirs"])
        store.upsert(host("second"))

        XCTAssertTrue(store.externalChange, "the store must notice it would be clobbering")
        let onDisk = SessionStore(fileURL: tempURL)
        XCTAssertEqual(onDisk.entries.map(\.name), ["theirs"],
                       "their edit must survive; ours is the one that waits")
    }

    func testReloadingTakesTheOnDiskCopyAndClearsTheConflict() throws {
        let store = SessionStore(fileURL: tempURL)
        store.upsert(host("mine"))
        try writeBehindItsBack(["theirs"])
        store.upsert(host("second"))
        XCTAssertTrue(store.externalChange)

        store.reloadAfterExternalChange()

        XCTAssertFalse(store.externalChange)
        XCTAssertEqual(store.entries.map(\.name), ["theirs"])
        // And saving works again afterwards.
        store.upsert(host("after"))
        XCTAssertFalse(store.externalChange)
        XCTAssertEqual(Set(SessionStore(fileURL: tempURL).entries.map(\.name)), ["theirs", "after"])
    }

    func testOverwritingIsOfferedSoAConflictCannotBecomePermanent() throws {
        // Refusing forever is its own failure mode: a sync client with a
        // stale clock would otherwise leave the library permanently read-only.
        let store = SessionStore(fileURL: tempURL)
        store.upsert(host("mine"))
        try writeBehindItsBack(["theirs"])
        store.upsert(host("second"))
        XCTAssertTrue(store.externalChange)

        store.overwriteExternalChange()

        XCTAssertFalse(store.externalChange)
        let onDisk = SessionStore(fileURL: tempURL)
        XCTAssertTrue(onDisk.entries.contains { $0.name == "mine" },
                      "the in-memory library won, deliberately")
    }

    func testAFirstRunWithNoFileYetSavesNormally() {
        // Nothing on disk means nothing to conflict with.
        let store = SessionStore(fileURL: tempURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path))
        store.upsert(host("first"))
        XCTAssertFalse(store.externalChange)
        XCTAssertEqual(SessionStore(fileURL: tempURL).entries.count, 1)
    }

    func testAnUnreadableLibraryStillTakesPrecedence() throws {
        // The older rule stays the stronger one: a library that wouldn't decode
        // must not be written over, conflict or not.
        try #"{"entries":[{"#.write(to: tempURL, atomically: true, encoding: .utf8)
        let store = SessionStore(fileURL: tempURL)
        XCTAssertNotNil(store.loadFailure)

        store.upsert(host("web"))

        let raw = try String(contentsOf: tempURL, encoding: .utf8)
        XCTAssertTrue(raw.hasPrefix(#"{"entries":[{"#), "the quarantined original is untouched")
    }
}
