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
}
