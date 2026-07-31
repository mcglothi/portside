import XCTest
@testable import Portside

/// Batch move/delete and folder-tree behavior behind the NSOutlineView sidebar.
/// Each store is backed by a throwaway temp file so the real library is never
/// touched.
final class SessionStoreTests: XCTestCase {
    private var tempURL: URL!

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-test-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        try? FileManager.default.removeItem(
            at: tempURL.deletingPathExtension().appendingPathExtension("history.json"))
        super.tearDown()
    }

    private func makeStore(_ entries: [SessionEntry]) -> SessionStore {
        let store = SessionStore(fileURL: tempURL)
        for entry in entries { store.upsert(entry) }
        return store
    }

    private func host(_ name: String, folder: String = "") -> SessionEntry {
        SessionEntry(name: name, folder: folder, hostname: "\(name).example.com")
    }

    // MARK: - Command history

    private func enableCommands(_ store: SessionStore) {
        var settings = store.history
        settings.keepCommandHistory = true
        store.updateHistorySettings(settings)
    }

    func testCommandsAreNotRecordedUntilOptedIn() {
        let store = makeStore([])
        store.recordCommand(CommandEvent(command: "ls", startedAt: Date()))
        XCTAssertTrue(store.commandHistory.isEmpty, "recording must be opt-in")
    }

    func testOptedInCommandsPersist() {
        let a = host("a")
        let store = makeStore([a])
        enableCommands(store)
        store.recordCommand(CommandEvent(entryID: a.id, command: "uptime", startedAt: Date()))

        let reloaded = SessionStore(fileURL: tempURL)
        XCTAssertEqual(reloaded.commandHistory.map(\.command), ["uptime"])
    }

    func testTurningCommandHistoryOffDiscardsWhatWasRecorded() {
        // Opting out has to actually remove the plaintext command lines, or
        // opting out doesn't mean much.
        let store = makeStore([])
        enableCommands(store)
        store.recordCommand(CommandEvent(command: "secret --token abc", startedAt: Date()))
        XCTAssertEqual(store.commandHistory.count, 1)

        var settings = store.history
        settings.keepCommandHistory = false
        store.updateHistorySettings(settings)

        XCTAssertTrue(store.commandHistory.isEmpty)
        let reloaded = SessionStore(fileURL: tempURL)
        XCTAssertTrue(reloaded.commandHistory.isEmpty, "and it must be gone from disk too")
    }

    func testProtectedHostsAreExcludedFromCommandsWhenAsked() {
        var prod = host("prod")
        prod.isProtected = true
        let store = makeStore([prod])
        var settings = store.history
        settings.keepCommandHistory = true
        settings.excludeProtectedHosts = true
        store.updateHistorySettings(settings)

        store.recordCommand(CommandEvent(entryID: prod.id, command: "systemctl restart", startedAt: Date()))
        XCTAssertTrue(store.commandHistory.isEmpty, "excluding a host must cover commands too")
    }

    func testCommandHistoryIsCappedOldestFirst() {
        let store = makeStore([])
        var settings = store.history
        settings.keepCommandHistory = true
        settings.commandLimit = 3
        store.updateHistorySettings(settings)

        for i in 0..<5 {
            store.recordCommand(CommandEvent(command: "cmd\(i)",
                                             startedAt: Date(timeIntervalSince1970: Double(i))))
        }
        XCTAssertEqual(store.commandHistory.map(\.command), ["cmd2", "cmd3", "cmd4"])
    }

    func testClearHistoryRemovesCommandsToo() {
        let store = makeStore([])
        enableCommands(store)
        store.recordCommand(CommandEvent(command: "ls", startedAt: Date()))
        store.clearHistory()
        XCTAssertTrue(store.commandHistory.isEmpty)
    }

    func testCommandsCanBeScopedToAHostNewestFirst() {
        let a = host("a"), b = host("b")
        let store = makeStore([a, b])
        enableCommands(store)
        store.recordCommand(CommandEvent(entryID: a.id, command: "old", startedAt: Date(timeIntervalSince1970: 1)))
        store.recordCommand(CommandEvent(entryID: a.id, command: "new", startedAt: Date(timeIntervalSince1970: 9)))
        store.recordCommand(CommandEvent(entryID: b.id, command: "other", startedAt: Date(timeIntervalSince1970: 5)))

        XCTAssertEqual(store.commands(forEntry: a.id).map(\.command), ["new", "old"])
        XCTAssertEqual(store.commands().count, 3)
    }

    // MARK: - History file separation

    private var historyURL: URL {
        tempURL.deletingPathExtension().appendingPathExtension("history.json")
    }

    func testCommandsGoToTheHistoryFileNotTheLibrary() {
        // Recording a command must not rewrite the host library, and must not
        // leave command lines anywhere Export Sessions would pick them up.
        let store = makeStore([host("a")])
        enableCommands(store)
        store.recordCommand(CommandEvent(command: "curl -H 'Authorization: secret'", startedAt: Date()))

        let library = try! String(contentsOf: tempURL, encoding: .utf8)
        XCTAssertFalse(library.contains("Authorization: secret"),
                       "command lines must not be written into the exportable library")
        let history = try! String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertTrue(history.contains("Authorization: secret"))
    }

    func testHistoryInAnOlderLibraryIsMigratedOut() {
        // Anything recorded before history moved to its own file has to carry
        // over, not silently vanish on upgrade.
        let entryID = UUID()
        let legacy = """
        {"entries":[],"macros":[],
         "commandHistory":[{"id":"\(UUID().uuidString)","command":"uptime",
                            "startedAt":760000000}],
         "connectionStats":[{"entryID":"\(entryID.uuidString)","count":4,
                             "lastConnected":760000000}]}
        """
        try! legacy.write(to: tempURL, atomically: true, encoding: .utf8)

        let store = SessionStore(fileURL: tempURL)
        XCTAssertEqual(store.commandHistory.map(\.command), ["uptime"])
        XCTAssertEqual(store.stat(for: entryID)?.count, 4)

        // ...and it now lives in the sidecar, with the library cleaned up.
        XCTAssertTrue(FileManager.default.fileExists(atPath: historyURL.path))
        let library = try! String(contentsOf: tempURL, encoding: .utf8)
        XCTAssertFalse(library.contains("uptime"), "the legacy copy should not be left behind")
    }

    func testHistorySurvivesReload() {
        let store = makeStore([])
        enableCommands(store)
        store.recordCommand(CommandEvent(command: "make", startedAt: Date()))

        let reloaded = SessionStore(fileURL: tempURL)
        XCTAssertEqual(reloaded.commandHistory.map(\.command), ["make"])
    }

    // MARK: - Corrupt library handling

    func testUnreadableLibraryIsPreservedNotOverwritten() throws {
        // The 900-host case: a schema bug or bad hand-edit used to be treated
        // as a first launch, reseeding from ~/.ssh/config and saving over the
        // top -- destroying a library that was probably still recoverable.
        let corrupt = #"{"entries":[{"name":"prod-web-01","#
        try corrupt.write(to: tempURL, atomically: true, encoding: .utf8)

        let store = SessionStore(fileURL: tempURL)

        XCTAssertNotNil(store.loadFailure, "the failure must be recorded, not swallowed")
        let onDisk = try String(contentsOf: tempURL, encoding: .utf8)
        XCTAssertEqual(onDisk, corrupt, "the original library must be left exactly as it was")

        let quarantine = try XCTUnwrap(store.quarantinedLibraryPath)
        XCTAssertEqual(try String(contentsOfFile: quarantine, encoding: .utf8), corrupt)
        try? FileManager.default.removeItem(atPath: quarantine)
    }

    func testAStoreInFailureStateRefusesToSave() throws {
        let corrupt = "{ definitely not json"
        try corrupt.write(to: tempURL, atomically: true, encoding: .utf8)
        let store = SessionStore(fileURL: tempURL)
        if let q = store.quarantinedLibraryPath {
            addTeardownBlock { try? FileManager.default.removeItem(atPath: q) }
        }

        // Any mutation would normally persist; here it must not reach disk.
        store.upsert(host("new-host"))

        XCTAssertEqual(try String(contentsOf: tempURL, encoding: .utf8), corrupt,
                       "a bad read must never become a bad write")
    }

    func testMissingLibraryIsStillATrueFirstLaunch() {
        // Quarantine must not fire for a file that simply isn't there.
        try? FileManager.default.removeItem(at: tempURL)
        let store = SessionStore(fileURL: tempURL)
        XCTAssertNil(store.loadFailure)
        XCTAssertNil(store.quarantinedLibraryPath)
    }

    func testUnreadableHistorySidecarIsPreservedAndDoesNotBlockTheApp() throws {
        let store = makeStore([host("a")])       // writes a valid library
        let historyURL = tempURL.deletingPathExtension().appendingPathExtension("history.json")
        try "{ broken".write(to: historyURL, atomically: true, encoding: .utf8)

        let reloaded = SessionStore(fileURL: tempURL)
        XCTAssertNil(reloaded.loadFailure, "bad history must not take the library down with it")
        XCTAssertEqual(reloaded.entries.count, 1)
        _ = store
    }

    // MARK: - Connection outcomes

    func testFailedAttemptDoesNotCountAsAConnection() {
        // Regression: every attempt counted, so a host you keep failing to
        // reach climbed the ranking and never went stale.
        let a = host("a")
        let store = makeStore([a])
        store.recordConnection(a, outcome: .failed)

        XCTAssertNil(store.stat(for: a.id), "a failure must not create a total")
        XCTAssertTrue(store.frecentEntries(limit: 5).isEmpty)
    }

    func testAttemptAloneDoesNotCount() {
        let a = host("a")
        let store = makeStore([a])
        store.recordConnection(a, outcome: .attempted)
        XCTAssertNil(store.stat(for: a.id))
    }

    func testConfirmedConnectionCounts() {
        let a = host("a")
        let store = makeStore([a])
        store.recordConnection(a, outcome: .connected)
        XCTAssertEqual(store.stat(for: a.id)?.count, 1)
    }

    func testFailuresStillAppearInTheFullLog() {
        // The aggregate ignores failures; the log shouldn't -- "I couldn't get
        // in at 14:32" is exactly what a log is for.
        let a = host("a")
        let store = makeStore([a])
        var settings = store.history
        settings.keepFullLog = true
        store.updateHistorySettings(settings)

        store.recordConnection(a, outcome: .failed)
        XCTAssertEqual(store.connectionLog.map(\.outcome), [.failed])
        XCTAssertNil(store.stat(for: a.id))
    }

    func testOlderLogEntriesWithoutAnOutcomeStillDecode() {
        let json = Data(#"{"eventID":"\#(UUID().uuidString)","entryID":"\#(UUID().uuidString)","at":760000000}"#.utf8)
        let entry = try? JSONDecoder().decode(ConnectionLogEntry.self, from: json)
        XCTAssertNotNil(entry)
        XCTAssertNil(entry?.outcome)
    }

    func testUnknownOutcomeFromANewerBuildDecodesTolerantly() {
        let json = Data("\"quantum-tunnelled\"".utf8)
        XCTAssertEqual(try? JSONDecoder().decode(ConnectionOutcome.self, from: json), .attempted)
    }

    // MARK: - Quick Connect continuity across upgrade

    func testExistingRecentsSeedStatsSoQuickConnectKeepsItsOrder() {
        // Regression: with no stats, Quick Connect fell back to recents; the
        // first new connection created one stat and every other recently-used
        // host silently dropped out of the ranking.
        let a = host("a"), b = host("b"), c = host("c")
        let store = makeStore([a, b, c])
        store.recordConnection(a)
        store.recordConnection(b)
        store.recordConnection(c)

        // Simulate an upgrade: recents present, aggregate absent.
        let historyURL = tempURL.deletingPathExtension().appendingPathExtension("history.json")
        try? FileManager.default.removeItem(at: historyURL)

        let upgraded = SessionStore(fileURL: tempURL)
        XCTAssertEqual(upgraded.connectionStats.count, 3,
                       "every remembered host should carry into the ranking")
        XCTAssertEqual(Set(upgraded.frecentEntries(limit: 10).map(\.name)), ["a", "b", "c"])
    }

    func testSeedingDoesNotRunOnceStatsExist() {
        let a = host("a")
        let store = makeStore([a])
        store.recordConnection(a)
        store.recordConnection(a)
        XCTAssertEqual(store.stat(for: a.id)?.count, 2)

        let reloaded = SessionStore(fileURL: tempURL)
        XCTAssertEqual(reloaded.stat(for: a.id)?.count, 2,
                       "real counts must not be overwritten by seeding")
    }

    // MARK: - Migration must not destroy the library

    func testMigratingLegacyHistoryPreservesProfilesAndBindings() {
        // Regression: the migration wrote the library part-way through load(),
        // before profiles/keybindings/workspace/defaultProfileID had been read
        // -- so upgrading silently wiped a user's credential profiles.
        let profileID = UUID()
        let legacy = """
        {"entries":[],"macros":[],
         "credentialProfiles":[{"id":"\(profileID.uuidString)","name":"Standard AD"}],
         "defaultProfileID":"\(profileID.uuidString)",
         "commandHistory":[{"id":"\(UUID().uuidString)","command":"uptime","startedAt":760000000}]}
        """
        try! legacy.write(to: tempURL, atomically: true, encoding: .utf8)

        _ = SessionStore(fileURL: tempURL)

        let reloaded = SessionStore(fileURL: tempURL)
        XCTAssertEqual(reloaded.credentialProfiles.map(\.name), ["Standard AD"],
                       "migration must not drop credential profiles")
        XCTAssertEqual(reloaded.defaultProfileID, profileID)
        XCTAssertEqual(reloaded.commandHistory.map(\.command), ["uptime"])
    }

    func testDisablingTheConnectionLogActuallyDeletesItFromDisk() {
        // Regression: the log was persisted before being cleared, so it came
        // back on next launch and the promised deletion never happened.
        let a = host("a")
        let store = makeStore([a])
        var settings = store.history
        settings.keepFullLog = true
        store.updateHistorySettings(settings)
        store.recordConnection(a, outcome: .connected)
        XCTAssertFalse(store.connectionLog.isEmpty)

        settings.keepFullLog = false
        store.updateHistorySettings(settings)

        XCTAssertTrue(store.connectionLog.isEmpty)
        let reloaded = SessionStore(fileURL: tempURL)
        XCTAssertTrue(reloaded.connectionLog.isEmpty,
                      "opting out has to survive a relaunch, not just clear memory")
    }

    // MARK: - Recording privacy

    func testProtectedHostGetsNoTranscriptWhenExcluded() {
        // The hole this closes: excluding a protected host used to stop its
        // connection and command records while its full terminal transcript
        // -- including anything echoed to screen -- kept being written.
        var prod = SessionEntry(name: "prod", hostname: "prod.example.com")
        prod.isProtected = true
        var logging = LoggingSettings()
        logging.enabled = true
        logging.directoryPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-logtest-\(UUID().uuidString)").path

        XCTAssertNil(
            LogManager.makeLogger(for: prod, settings: logging, excludeProtected: true),
            "a protected host must not get a transcript when excluded"
        )
        let logger = LogManager.makeLogger(for: prod, settings: logging, excludeProtected: false)
        XCTAssertNotNil(logger, "and must still get one when not excluded")
        logger?.close()
        try? FileManager.default.removeItem(atPath: logging.directoryPath)
    }

    func testUnprotectedHostIsUnaffectedByTheExclusion() {
        let ordinary = SessionEntry(name: "dev", hostname: "dev.example.com")
        var logging = LoggingSettings()
        logging.enabled = true
        logging.directoryPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-logtest-\(UUID().uuidString)").path

        let logger = LogManager.makeLogger(for: ordinary, settings: logging, excludeProtected: true)
        XCTAssertNotNil(logger)
        logger?.close()
        try? FileManager.default.removeItem(atPath: logging.directoryPath)
    }

    // MARK: - Bulk environment tagging

    func testSetEnvironmentTagsOnlyTheSelection() {
        let a = host("a"), b = host("b"), c = host("c")
        let store = makeStore([a, b, c])

        store.setEnvironment(.prod, ids: [a.id, c.id])

        XCTAssertEqual(store.entry(id: a.id)?.environment, .prod)
        XCTAssertEqual(store.entry(id: c.id)?.environment, .prod)
        XCTAssertEqual(store.entry(id: b.id)?.environment, HostEnvironment.none,
                       "an unselected host must not be retagged")
    }

    func testSetEnvironmentCanClearBackToNone() {
        var a = host("a")
        a.environment = .prod
        let store = makeStore([a])

        store.setEnvironment(.none, ids: [a.id])

        XCTAssertEqual(store.entry(id: a.id)?.environment, HostEnvironment.none)
    }

    func testSetEnvironmentPersists() {
        let a = host("a")
        let store = makeStore([a])
        store.setEnvironment(.staging, ids: [a.id])

        // A bulk pass across a 900-host library is worthless if it doesn't survive relaunch.
        let reloaded = SessionStore(fileURL: tempURL)
        XCTAssertEqual(reloaded.entry(id: a.id)?.environment, .staging)
    }

    func testSetEnvironmentIgnoresUnknownIDs() {
        let a = host("a")
        let store = makeStore([a])
        store.setEnvironment(.dev, ids: [UUID()])
        XCTAssertEqual(store.entry(id: a.id)?.environment, HostEnvironment.none)
    }

    // MARK: - Batch move

    func testMoveEntryIDsRelocatesAllToFolder() {
        let a = host("a"), b = host("b"), c = host("c")
        let store = makeStore([a, b, c])

        store.move(entryIDs: [a.id, b.id], toFolder: "prod")

        XCTAssertEqual(store.entries.first { $0.id == a.id }?.folder, "prod")
        XCTAssertEqual(store.entries.first { $0.id == b.id }?.folder, "prod")
        XCTAssertEqual(store.entries.first { $0.id == c.id }?.folder, "")
    }

    func testMoveEntryIDsToTopLevelClearsFolder() {
        let a = host("a", folder: "prod"), b = host("b", folder: "prod/web")
        let store = makeStore([a, b])

        store.move(entryIDs: [a.id, b.id], toFolder: "")

        XCTAssertEqual(store.entries.first { $0.id == a.id }?.folder, "")
        XCTAssertEqual(store.entries.first { $0.id == b.id }?.folder, "")
    }

    func testMoveEntryIDsIgnoresUnknownIDs() {
        let a = host("a")
        let store = makeStore([a])

        store.move(entryIDs: [a.id, UUID()], toFolder: "staging")

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.folder, "staging")
    }

    func testMoveEntryIDsNoOpWhenAlreadyInFolder() {
        let a = host("a", folder: "prod")
        let store = makeStore([a])

        // Reload from disk after the move to prove nothing was rewritten needlessly:
        // if a spurious save happened it would still be "prod", so instead assert the
        // value is unchanged and the entry count is stable.
        store.move(entryIDs: [a.id], toFolder: "prod")

        XCTAssertEqual(store.entries.first?.folder, "prod")
    }

    // MARK: - Batch delete

    func testDeleteIDsRemovesOnlySelected() {
        let a = host("a"), b = host("b"), c = host("c")
        let store = makeStore([a, b, c])

        store.delete(ids: [a.id, c.id])

        XCTAssertEqual(store.entries.map(\.id), [b.id])
    }

    func testDeleteIDsIgnoresUnknownIDs() {
        let a = host("a")
        let store = makeStore([a])

        store.delete(ids: [UUID()])

        XCTAssertEqual(store.entries.count, 1)
    }

    func testDeleteEmptySetLeavesLibraryIntact() {
        let a = host("a"), b = host("b")
        let store = makeStore([a, b])

        store.delete(ids: [])

        XCTAssertEqual(store.entries.count, 2)
    }

    // MARK: - Persistence round-trip

    func testBatchMovePersistsToDisk() {
        let a = host("a"), b = host("b")
        let store = makeStore([a, b])
        store.move(entryIDs: [a.id, b.id], toFolder: "net")

        let reloaded = SessionStore(fileURL: tempURL)
        XCTAssertEqual(Set(reloaded.entries.map(\.folder)), ["net"])
    }

    // MARK: - FolderTree

    func testFolderTreeSplitsRootAndFolders() {
        let entries = [
            host("top"),
            host("web", folder: "prod"),
            host("db", folder: "prod"),
        ]
        let tree = FolderTree.build(entries: entries)

        XCTAssertEqual(tree.root.map(\.name), ["top"])
        XCTAssertEqual(tree.folders.map(\.path), ["prod"])
        XCTAssertEqual(tree.folders.first?.entries.map(\.name), ["db", "web"]) // alpha
    }

    func testFolderTreeMaterializesAncestors() {
        let entries = [host("deep", folder: "a/b/c")]
        let tree = FolderTree.build(entries: entries)

        // Every ancestor exists as a node even though only the leaf holds a host.
        XCTAssertEqual(tree.folders.map(\.path), ["a"])
        let b = tree.folders.first?.subfolders.first
        XCTAssertEqual(b?.path, "a/b")
        XCTAssertEqual(b?.subfolders.first?.path, "a/b/c")
        XCTAssertEqual(b?.subfolders.first?.entries.map(\.name), ["deep"])
    }

    func testFolderTreeIncludesEmptyExplicitFolders() {
        let tree = FolderTree.build(entries: [], explicitFolders: ["empty"])
        XCTAssertEqual(tree.folders.map(\.path), ["empty"])
        XCTAssertTrue(tree.folders.first?.entries.isEmpty ?? false)
    }

    // MARK: - Credential profiles
    //
    // These deliberately never touch a profile's Keychain password
    // (CredentialStore.setProfilePassword/profilePassword/deleteProfilePassword)
    // — CredentialStore isn't test-isolated and hits the real system Keychain,
    // which bit us once already (see SessionStore.migrateLegacyDefault, only
    // ever invoked when seedsFromSSHConfig is true, which the test seam here
    // always passes as false). `delete(_ profile:)` below does call
    // CredentialStore.deleteProfilePassword, but on a throwaway UUID that
    // never had anything stored, so it's a harmless no-op.

    func testUpsertProfileAddsThenUpdatesInPlace() {
        let store = makeStore([])
        var profile = CredentialProfile(name: "Ops", user: "opsuser")
        store.upsert(profile)
        XCTAssertEqual(store.credentialProfiles.map(\.name), ["Ops"])

        profile.name = "Ops Renamed"
        store.upsert(profile)
        XCTAssertEqual(store.credentialProfiles.count, 1)
        XCTAssertEqual(store.credentialProfiles.first?.name, "Ops Renamed")
    }

    func testDeleteProfileClearsDefaultProfileIDWhenItWasTheDefault() {
        let store = makeStore([])
        let profile = CredentialProfile(name: "Ops")
        store.upsert(profile)
        store.defaultProfileID = profile.id

        store.delete(profile)

        XCTAssertTrue(store.credentialProfiles.isEmpty)
        XCTAssertNil(store.defaultProfileID)
    }

    func testDeletingProfileLeavesAssignedHostsPointingAtUnknownID() {
        // Resolution treats an unknown id as "no profile assigned" rather
        // than mutating every host that pointed at the deleted profile.
        var entry = host("a")
        let profile = CredentialProfile(name: "Ops", user: "opsuser")
        entry.credentialProfileID = profile.id
        let store = makeStore([entry])
        store.upsert(profile)

        store.delete(profile)

        XCTAssertEqual(store.entries.first?.credentialProfileID, profile.id)
        XCTAssertNil(store.credentialProfile(id: store.entries.first?.credentialProfileID))
    }

    func testApplyCredentialProfileAssignsAndFlipsSavePasswordOn() {
        let a = host("a"), b = host("b")
        let store = makeStore([a, b])
        let profile = CredentialProfile(name: "Ops")
        store.upsert(profile)

        store.applyCredentialProfile(profile.id, to: [a.id, b.id])

        for entry in store.entries {
            XCTAssertEqual(entry.credentialProfileID, profile.id)
            XCTAssertTrue(entry.savePassword)
        }
    }

    func testApplyCredentialProfileNilClearsAssignmentButLeavesSavePasswordAlone() {
        var a = host("a")
        a.savePassword = true
        let store = makeStore([a])
        let profile = CredentialProfile(name: "Ops")
        store.upsert(profile)
        store.applyCredentialProfile(profile.id, to: [a.id])

        store.applyCredentialProfile(nil, to: [a.id])

        let updated = store.entries.first { $0.id == a.id }
        XCTAssertNil(updated?.credentialProfileID)
        XCTAssertTrue(updated?.savePassword ?? false)
    }

    func testApplyCredentialProfileIgnoresIDsNotInSelection() {
        let a = host("a"), b = host("b")
        let store = makeStore([a, b])
        let profile = CredentialProfile(name: "Ops")
        store.upsert(profile)

        store.applyCredentialProfile(profile.id, to: [a.id])

        XCTAssertEqual(store.entries.first { $0.id == a.id }?.credentialProfileID, profile.id)
        XCTAssertNil(store.entries.first { $0.id == b.id }?.credentialProfileID)
    }

    // MARK: - Credential resolution precedence

    func testResolvedPrefersAssignedProfileOverHostsOwnStaleFields() {
        var entry = host("a")
        entry.user = "stale-user"
        entry.identityFile = "/old/key"
        let store = makeStore([entry])
        let profile = CredentialProfile(name: "Ops", user: "opsuser", identityFile: "/new/key")
        store.upsert(profile)
        store.applyCredentialProfile(profile.id, to: [entry.id])

        let resolved = store.resolved(store.entries.first { $0.id == entry.id }!)

        XCTAssertEqual(resolved.user, "opsuser")
        XCTAssertEqual(resolved.identityFile, "/new/key")
    }

    func testResolvedFallsBackToGlobalDefaultsWhenNoProfileAssigned() {
        let entry = host("a")
        let store = makeStore([entry])
        var defaults = store.defaults
        defaults.user = "default-user"
        store.updateDefaults(defaults)

        let resolved = store.resolved(store.entries.first!)

        XCTAssertEqual(resolved.user, "default-user")
    }

    func testResolvedTreatsUnknownProfileIDAsUnassigned() {
        var entry = host("a")
        entry.credentialProfileID = UUID()
        let store = makeStore([entry])

        let resolved = store.resolved(store.entries.first!)

        XCTAssertNil(resolved.user)
    }

    // MARK: - Codable round-trip / tolerant decode

    func testCredentialProfileRoundTrips() throws {
        let profile = CredentialProfile(name: "Ops", user: "opsuser", identityFile: "/key")
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(CredentialProfile.self, from: data)
        XCTAssertEqual(decoded, profile)
    }

    func testSessionEntryDecodesWithoutCredentialProfileIDField() throws {
        // A pre-profiles library entry — the key is simply absent.
        let json = """
        {"id":"\(UUID().uuidString)","name":"legacy","folder":"","hostname":"legacy.example.com"}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(SessionEntry.self, from: json)

        XCTAssertNil(decoded.credentialProfileID)
    }

    // MARK: - Favorites

    func testToggleFavoriteFlipsAndPersists() {
        let a = host("a")
        let store = makeStore([a])

        store.toggleFavorite(a.id)
        XCTAssertTrue(store.entries.first?.isFavorite ?? false)

        store.toggleFavorite(a.id)
        XCTAssertFalse(store.entries.first?.isFavorite ?? true)
    }

    func testToggleFavoriteIgnoresUnknownID() {
        let store = makeStore([host("a")])
        store.toggleFavorite(UUID())
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertFalse(store.entries.first?.isFavorite ?? true)
    }

    func testSetFavoriteBulkAppliesOnlyToSelection() {
        let a = host("a"), b = host("b")
        let store = makeStore([a, b])

        store.setFavorite(true, ids: [a.id])

        XCTAssertTrue(store.entries.first { $0.id == a.id }?.isFavorite ?? false)
        XCTAssertFalse(store.entries.first { $0.id == b.id }?.isFavorite ?? true)
    }

    func testFavoriteEntriesReturnsOnlyFavoritesSortedAlphabetically() {
        let z = host("zeta"), a = host("alpha"), m = host("mid")
        let store = makeStore([z, a, m])

        store.setFavorite(true, ids: [z.id, a.id])

        XCTAssertEqual(store.favoriteEntries.map(\.name), ["alpha", "zeta"])
    }

    func testSessionEntryDecodesWithoutIsFavoriteFieldDefaultingFalse() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"legacy","folder":"","hostname":"legacy.example.com"}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(SessionEntry.self, from: json)

        XCTAssertFalse(decoded.isFavorite)
    }

    func testStoreLoadsLegacyDocumentMissingCredentialProfileFields() throws {
        // A whole pre-profiles library file with no credentialProfiles/
        // defaultProfileID keys at all.
        let entryData = try JSONEncoder().encode(host("a"))
        let entryJSON = String(data: entryData, encoding: .utf8)!
        let json = "{\"entries\":[\(entryJSON)],\"macros\":[]}".data(using: .utf8)!
        try json.write(to: tempURL)

        let store = SessionStore(fileURL: tempURL)

        XCTAssertTrue(store.credentialProfiles.isEmpty)
        XCTAssertNil(store.defaultProfileID)
        XCTAssertEqual(store.entries.count, 1)
    }

    // MARK: - Import dedup

    func testImportExportDedupesWithinTheIncomingBatch() {
        // The key set used to be snapshotted against the library only, so a
        // file listing the same host twice imported it twice.
        let store = makeStore([])
        let dupe = host("web")

        let added = store.importExport(entries: [dupe, dupe], folders: [], macros: [])

        XCTAssertEqual(added.sessions, 1)
        XCTAssertEqual(store.entries.filter { $0.name == "web" }.count, 1)
    }

    func testAddImportedDedupesWithinTheIncomingBatch() {
        let store = makeStore([])
        let dupe = host("web")

        let added = store.addImported(entries: [dupe, dupe], macros: [])

        XCTAssertEqual(added.sessions, 1)
        XCTAssertEqual(store.entries.filter { $0.name == "web" }.count, 1)
    }

    func testImportDedupesMacrosWithinTheIncomingBatch() {
        let store = makeStore([])
        let macro = Macro(name: "restart", text: "systemctl restart nginx")

        let added = store.importExport(entries: [], folders: [], macros: [macro, macro])

        XCTAssertEqual(added.macros, 1)
        XCTAssertEqual(store.macros.filter { $0.name == "restart" }.count, 1)
    }

    func testSameNameInADifferentFolderIsNotADuplicate() {
        let store = makeStore([])
        let a = host("web", folder: "prod")
        let b = host("web", folder: "staging")

        let added = store.importExport(entries: [a, b], folders: [], macros: [])

        XCTAssertEqual(added.sessions, 2, "folder is part of the identity")
    }

    /// The invariant that matters isn't "the UUID survived" — it's "the entry
    /// can still authenticate". `CredentialResolver` gates every source behind
    /// `savePassword`, so a retained profile id with the flag off is a pointer
    /// to a credential that can never be used.
    private func resolvedSource(_ entry: SessionEntry, hasProfilePassword: Bool) -> CredentialResolver.Source {
        CredentialResolver.source(
            savePassword: entry.savePassword,
            hasAssignedProfilePassword: entry.credentialProfileID != nil && hasProfilePassword,
            hasHostPassword: false,        // import always assigns a fresh id
            hasDefaultProfilePassword: false,
            hasLegacyDefault: false
        )
    }

    func testARetainedProfileIsActuallyUsableNotJustRetained() {
        let store = makeStore([])
        let profile = CredentialProfile(name: "Ops", user: "opsuser")
        store.upsert(profile)
        var entry = host("web")
        entry.credentialProfileID = profile.id
        entry.savePassword = true

        store.importExport(entries: [entry], folders: [], macros: [])

        let imported = store.entries.first!
        XCTAssertEqual(resolvedSource(imported, hasProfilePassword: true), .assignedProfile,
                       "a profile that resolves locally must still authenticate after import")
    }

    func testAnUnresolvableProfileLeavesTheEntryUnableToAuthenticate() {
        let store = makeStore([])
        var entry = host("web")
        entry.credentialProfileID = UUID()
        entry.savePassword = true

        store.importExport(entries: [entry], folders: [], macros: [])

        let imported = store.entries.first!
        XCTAssertNil(imported.credentialProfileID)
        XCTAssertFalse(imported.savePassword)
        XCTAssertEqual(resolvedSource(imported, hasProfilePassword: true), .none,
                       "a dangling profile must not fall through to this machine's credentials")
    }

    func testImportNormalisesAHandEditedInconsistentEntry() {
        // "Profile assigned, saved passwords off" can only come from a
        // hand-edited library — applyCredentialProfile and the editor's
        // profile binding both set the flag on assignment, and the editor
        // hides the toggle while a profile is assigned. Carrying it through
        // would leave the editor saying "password is set by the Ops profile"
        // for an entry that resolves to nothing.
        let store = makeStore([])
        let profile = CredentialProfile(name: "Ops", user: "opsuser")
        store.upsert(profile)
        var entry = host("web")
        entry.credentialProfileID = profile.id
        entry.savePassword = false

        store.importExport(entries: [entry], folders: [], macros: [])

        let imported = store.entries.first!
        XCTAssertEqual(imported.credentialProfileID, profile.id)
        XCTAssertTrue(imported.savePassword, "an assigned profile must be a usable one")
        XCTAssertEqual(resolvedSource(imported, hasProfilePassword: true), .assignedProfile)
    }

    func testImportWithoutAProfileCannotInheritLocalCredentials() {
        let store = makeStore([])
        var entry = host("web")
        entry.savePassword = true      // was a host-specific password elsewhere

        store.importExport(entries: [entry], folders: [], macros: [])

        // The host password was keyed by the old id, which import discards.
        XCTAssertFalse(store.entries.first!.savePassword)
    }

    func testImportKeyDoesNotCollideAcrossFolderAndNameBoundaries() {
        // Folder and name are free text. A joined-string key made "a|b" + "c"
        // and "a" + "b|c" the same session, silently dropping one.
        let store = makeStore([])
        let first = SessionEntry(name: "c", folder: "a|b", hostname: "h.example.com")
        let second = SessionEntry(name: "b|c", folder: "a", hostname: "h.example.com")

        let added = store.importExport(entries: [first, second], folders: [], macros: [])

        XCTAssertEqual(added.sessions, 2, "these are distinct sessions")
    }

    func testImportClearsACredentialProfileIDThatDoesNotResolveHere() {
        // Profiles don't travel in an export, so an id from another machine
        // would otherwise dangle — silently meaning "no credential" while the
        // entry still claims a profile.
        let store = makeStore([])
        var entry = host("web")
        entry.credentialProfileID = UUID()   // never existed in this library

        store.importExport(entries: [entry], folders: [], macros: [])

        XCTAssertNil(store.entries.first?.credentialProfileID)
    }

    func testImportKeepsACredentialProfileIDThatStillResolves() {
        // Restoring your own backup on the same machine: the ids do match, and
        // clearing them would quietly strip every host's credential.
        let store = makeStore([])
        let profile = CredentialProfile(name: "Ops", user: "opsuser")
        store.upsert(profile)
        var entry = host("web")
        entry.credentialProfileID = profile.id

        store.importExport(entries: [entry], folders: [], macros: [])

        XCTAssertEqual(store.entries.first?.credentialProfileID, profile.id)
    }

    // MARK: - History write coalescing

    func testDebouncedHistoryWritesAreCoalescedUntilFlushed() throws {
        let store = SessionStore(fileURL: tempURL, coalescesHistoryWrites: true)
        enableCommands(store)
        let historyURL = tempURL.deletingPathExtension().appendingPathExtension("history.json")
        try? FileManager.default.removeItem(at: historyURL)

        store.recordCommand(CommandEvent(command: "uptime", startedAt: Date()))
        store.recordCommand(CommandEvent(command: "df -h", startedAt: Date()))

        XCTAssertFalse(FileManager.default.fileExists(atPath: historyURL.path),
                       "a burst of commands must not rewrite the file per command")

        store.flushHistory()

        let written = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertTrue(written.contains("uptime"))
        XCTAssertTrue(written.contains("df -h"), "the whole burst lands on flush")
    }

    /// Polls for the history file rather than sleeping a fixed duration, so
    /// the test spins the main run loop the timer needs and doesn't hard-code
    /// how fast the machine is.
    private func waitForHistoryFile(_ url: URL, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func testTheCoalescedWriteFiresOnItsOwnWithoutAnExplicitFlush() throws {
        // The production path: nothing calls flushHistory(), so the timer has
        // to actually land the write.
        let store = SessionStore(fileURL: tempURL, coalescesHistoryWrites: true)
        enableCommands(store)
        let historyURL = tempURL.deletingPathExtension().appendingPathExtension("history.json")
        try? FileManager.default.removeItem(at: historyURL)

        store.recordCommand(CommandEvent(command: "uptime", startedAt: Date()))

        XCTAssertTrue(waitForHistoryFile(historyURL, timeout: 5),
                      "the coalescing window must eventually write by itself")
        let written = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertTrue(written.contains("uptime"))
    }

    func testSustainedActivityCannotPostponeTheWriteIndefinitely() throws {
        // A trailing-edge debounce rearms on every event, so a stream spaced
        // closer than the window never writes at all — the failure mode is
        // worst exactly when there's most to lose. The window is fixed: it
        // opens on the first event and fires regardless of what follows.
        let store = SessionStore(fileURL: tempURL, coalescesHistoryWrites: true)
        enableCommands(store)
        let historyURL = tempURL.deletingPathExtension().appendingPathExtension("history.json")
        try? FileManager.default.removeItem(at: historyURL)

        // Events every ~100ms for ~3s — far longer than the 750ms window, and
        // never idle long enough for a trailing-edge timer to expire.
        let deadline = Date().addingTimeInterval(3.0)
        var landedDuringStream = false
        var count = 0
        while Date() < deadline {
            store.recordCommand(CommandEvent(command: "cmd-\(count)", startedAt: Date()))
            count += 1
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            if FileManager.default.fileExists(atPath: historyURL.path) {
                landedDuringStream = true
                break
            }
        }

        XCTAssertTrue(landedDuringStream,
                      "a write must land while events are still arriving, not only once they stop")
    }

    func testClearingHistoryDropsAPendingWriteRatherThanLettingItLand() throws {
        // A coalesced write still holding pre-clear data must not be allowed
        // to fire afterwards and resurrect what was just deleted.
        let store = SessionStore(fileURL: tempURL, coalescesHistoryWrites: true)
        enableCommands(store)
        store.recordCommand(CommandEvent(command: "secret-command", startedAt: Date()))

        store.clearHistory()

        let historyURL = tempURL.deletingPathExtension().appendingPathExtension("history.json")
        let written = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertFalse(written.contains("secret-command"))
    }
}
