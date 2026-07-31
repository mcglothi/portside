import XCTest
@testable import Portside

/// Splitting machine-local state out of the library into `portside.local.json`.
///
/// The migration runs against every existing library exactly once, so these
/// lean on the failure modes rather than the happy path: state lost between the
/// two files, the migration undoing itself on the next save, and the library
/// being rewritten by things that no longer belong to it.
final class LibrarySplitTests: XCTestCase {
    private var tempURL: URL!
    private var localURL: URL { tempURL.deletingPathExtension().appendingPathExtension("local.json") }
    private var historyURL: URL { tempURL.deletingPathExtension().appendingPathExtension("history.json") }

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-split-\(UUID().uuidString).json")
    }

    private var preSplitURL: URL {
        tempURL.deletingPathExtension().appendingPathExtension("pre-local-split.json")
    }

    override func tearDown() {
        for url in [tempURL, localURL, historyURL, preSplitURL] {
            try? FileManager.default.removeItem(at: url!)
        }
        super.tearDown()
    }

    private func host(_ name: String) -> SessionEntry {
        SessionEntry(name: name, folder: "", hostname: "\(name).example.com")
    }

    /// A library in the pre-split shape: everything in one file.
    private func writeCombinedLibrary(entryName: String = "web-01") throws {
        let entry = host(entryName)
        let entryJSON = String(data: try JSONEncoder().encode([entry]), encoding: .utf8)!
        let recentJSON = String(
            data: try JSONEncoder().encode([RecentConnection(entryID: entry.id, date: Date())]),
            encoding: .utf8)!
        let json = """
        {"entries":\(entryJSON),"macros":[],
         "recents":\(recentJSON),
         "workspace":{"tabs":[{"root":{"leaf":{"_0":{"kind":{"localShell":{}},
                                                     "includedInMultiExec":true}}}}],
                      "selectedTabIndex":0,"wasGridView":false},
         "terminal":{"scrollbackLines":4321},
         "appearance":{"fontSize":19}}
        """
        try json.write(to: tempURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Migration

    func testLocalStateMovesOutOfTheLibraryOnFirstLoad() throws {
        try writeCombinedLibrary()

        let store = SessionStore(fileURL: tempURL)

        // Everything still readable through the store...
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.workspace.tabs.count, 1)
        XCTAssertEqual(store.terminal.scrollbackLines, 4321)
        XCTAssertEqual(store.recents.count, 1)

        // ...and it now lives in the sidecar.
        XCTAssertTrue(FileManager.default.fileExists(atPath: localURL.path))
        let local = try String(contentsOf: localURL, encoding: .utf8)
        XCTAssertTrue(local.contains("4321"))
    }

    func testTheLibraryStopsCarryingLocalStateAfterMigrating() throws {
        try writeCombinedLibrary()
        _ = SessionStore(fileURL: tempURL)

        let library = try String(contentsOf: tempURL, encoding: .utf8)
        XCTAssertFalse(library.contains("4321"), "terminal settings should be gone from the library")
        XCTAssertFalse(library.contains("\"workspace\""), "open tabs should be gone from the library")
        XCTAssertFalse(library.contains("\"recents\""))
        XCTAssertTrue(library.contains("web-01"), "the hosts must obviously stay")
    }

    func testMigratedStateSurvivesAReload() throws {
        try writeCombinedLibrary()
        _ = SessionStore(fileURL: tempURL)

        let reloaded = SessionStore(fileURL: tempURL)
        XCTAssertEqual(reloaded.terminal.scrollbackLines, 4321)
        XCTAssertEqual(reloaded.workspace.tabs.count, 1)
        XCTAssertEqual(reloaded.recents.count, 1)
        XCTAssertEqual(reloaded.entries.count, 1)
    }

    func testMigrationWritesTheSidecarBeforeStrippingTheLibrary() throws {
        // If it went the other way and the second write failed, the state would
        // be gone from both files. The observable stand-in: after migrating,
        // both a full reload and the sidecar alone still have it.
        try writeCombinedLibrary()
        _ = SessionStore(fileURL: tempURL)

        let local = try Data(contentsOf: localURL)
        let decoded = try JSONSerialization.jsonObject(with: local) as? [String: Any]
        XCTAssertNotNil(decoded?["workspace"])
        XCTAssertNotNil(decoded?["terminal"])
        XCTAssertNotNil(decoded?["recents"])
    }

    // MARK: - The point of the split

    func testChangingTheWorkspaceNoLongerRewritesTheLibrary() throws {
        // The reason to do this at all: every tab opened, closed or selected
        // used to rewrite every host, folder, macro, group and profile.
        let store = SessionStore(fileURL: tempURL)
        store.upsert(host("web-01"))
        let before = try FileManager.default
            .attributesOfItem(atPath: tempURL.path)[.modificationDate] as? Date

        store.saveWorkspace(WorkspaceSnapshot(
            tabs: [WorkspaceSnapshot.TabSnapshot(root: .leaf(
                WorkspaceSnapshot.Leaf(kind: .localShell, includedInMultiExec: true)))],
            selectedTabIndex: 0))

        let after = try FileManager.default
            .attributesOfItem(atPath: tempURL.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after, "the host library must not be touched by a tab change")
        XCTAssertTrue(FileManager.default.fileExists(atPath: localURL.path))
    }

    func testAFreshInstallReadsAnExistingSidecar() {
        // The sidecar stands on its own: `loadLocal` used to run only when a
        // library file existed, so a library not yet written meant the local
        // state was silently ignored.
        let store = SessionStore(fileURL: tempURL)
        store.updateTerminal({ var t = TerminalSettings(); t.scrollbackLines = 777; return t }())
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path),
                       "nothing has touched the library yet")

        let reloaded = SessionStore(fileURL: tempURL)
        XCTAssertEqual(reloaded.terminal.scrollbackLines, 777)
    }

    // MARK: - Rollback

    func testTheLibraryIsPreservedBeforeMigrating() throws {
        // The migration is one-way and runs unattended on first launch, so this
        // is the restore point if it turns out to be wrong.
        try writeCombinedLibrary()
        let before = try String(contentsOf: tempURL, encoding: .utf8)

        let store = SessionStore(fileURL: tempURL)

        XCTAssertEqual(store.preMigrationLibraryPath, preSplitURL.path)
        XCTAssertEqual(try String(contentsOf: preSplitURL, encoding: .utf8), before,
                       "the copy must be the library exactly as it was")
    }

    func testThePreservedCopyIsNotOverwrittenByALaterRun() throws {
        // If a first attempt migrated and something later went wrong, the file
        // worth keeping is the one from before the *first* attempt.
        try writeCombinedLibrary(entryName: "original")
        _ = SessionStore(fileURL: tempURL)
        let firstCopy = try String(contentsOf: preSplitURL, encoding: .utf8)

        // Something puts the library back into the old shape and it migrates again.
        try writeCombinedLibrary(entryName: "later")
        _ = SessionStore(fileURL: tempURL)

        XCTAssertEqual(try String(contentsOf: preSplitURL, encoding: .utf8), firstCopy,
                       "the earliest copy is the one that matters")
        XCTAssertTrue(firstCopy.contains("original"))
    }

    func testALibraryThatNeverNeededMigratingLeavesNoCopy() {
        // No migration, no restore point to explain.
        let store = SessionStore(fileURL: tempURL)
        store.upsert(host("web-01"))

        XCTAssertNil(store.preMigrationLibraryPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: preSplitURL.path))
    }

    // MARK: - Failure modes

    func testAnUnreadableSidecarIsPreservedAndDoesNotBlockTheLibrary() throws {
        // Opposite treatment from the library, deliberately: this file holds a
        // window layout and a font size, so refusing to start over it would
        // cost far more than it protects.
        try writeCombinedLibrary()
        _ = SessionStore(fileURL: tempURL)
        try "{ not json".write(to: localURL, atomically: true, encoding: .utf8)

        let store = SessionStore(fileURL: tempURL)

        XCTAssertNil(store.loadFailure, "a bad sidecar must not fail the library")
        XCTAssertEqual(store.entries.count, 1, "the hosts still load")
        XCTAssertEqual(store.terminal.scrollbackLines, TerminalSettings().scrollbackLines,
                       "local state falls back to defaults")
        let preserved = try FileManager.default
            .contentsOfDirectory(atPath: tempURL.deletingLastPathComponent().path)
            .filter { $0.contains("local.unreadable-") }
        XCTAssertFalse(preserved.isEmpty, "the unreadable sidecar is kept, not discarded")
        for name in preserved {
            try? FileManager.default.removeItem(
                at: tempURL.deletingLastPathComponent().appendingPathComponent(name))
        }
    }

    func testAnUnreadableLibraryStillLoadsLocalState() throws {
        try writeCombinedLibrary()
        _ = SessionStore(fileURL: tempURL)                     // migrate
        try #"{"entries":[{"#.write(to: tempURL, atomically: true, encoding: .utf8)

        let store = SessionStore(fileURL: tempURL)

        XCTAssertNotNil(store.loadFailure)
        XCTAssertEqual(store.terminal.scrollbackLines, 4321,
                       "a broken host list is no reason to lose the window layout too")
        // Cleanup: the quarantine copy.
        let dir = tempURL.deletingLastPathComponent()
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        where name.contains("unreadable-") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    func testRecentsStillSeedTheRankingAcrossTheSplit() throws {
        // Ordering trap: history seeds its aggregate from `recents`, which now
        // load from the sidecar. Loading history first seeded from an empty
        // list and silently emptied Quick Connect's ranking on upgrade.
        try writeCombinedLibrary()

        let store = SessionStore(fileURL: tempURL)

        XCTAssertEqual(store.connectionStats.count, 1,
                       "the remembered host must carry into the ranking")
    }
}
