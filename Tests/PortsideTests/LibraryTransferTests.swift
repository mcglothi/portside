import XCTest
@testable import Portside

/// The export format as a *portable* artifact: what has to survive the trip to
/// another Mac, what must never travel, and what the file has to look like once
/// these start living in git.
final class LibraryTransferTests: XCTestCase {
    private var machineA: URL!
    private var machineB: URL!

    override func setUp() {
        super.setUp()
        machineA = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-a-\(UUID().uuidString).json")
        machineB = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-b-\(UUID().uuidString).json")
    }

    override func tearDown() {
        for url in [machineA, machineB].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(
                at: url.deletingPathExtension().appendingPathExtension("history.json"))
        }
        super.tearDown()
    }

    private func host(_ name: String, folder: String = "") -> SessionEntry {
        SessionEntry(name: name, folder: folder, hostname: "\(name).example.com")
    }

    /// Precedence without touching the Keychain, same seam the store tests use.
    private func source(_ entry: SessionEntry, profileHasPassword: Bool) -> CredentialResolver.Source {
        CredentialResolver.source(
            savePassword: entry.savePassword,
            hasAssignedProfilePassword: entry.credentialProfileID != nil && profileHasPassword,
            hasHostPassword: false,
            hasDefaultProfilePassword: false,
            hasLegacyDefault: false
        )
    }

    // MARK: - The scenario this phase exists for

    func testALibraryRestoredOnAnotherMacCanStillAuthenticate() throws {
        // Before profiles travelled, this was the whole bug: every host in a
        // restored library came back unable to authenticate, because its
        // profile reference pointed at a record that only existed on the Mac
        // the export came from.
        let a = SessionStore(fileURL: machineA)
        let profile = CredentialProfile(name: "Ops", user: "opsuser")
        a.upsert(profile)
        var web = host("web-01")
        web.credentialProfileID = profile.id
        web.savePassword = true
        a.upsert(web)

        let data = try LibraryTransfer.encodeSessions(
            entries: a.entries, folders: a.explicitFolders, credentialProfiles: a.credentialProfiles
        )

        let b = SessionStore(fileURL: machineB)
        let doc = try XCTUnwrap(LibraryTransfer.decode(data))
        let added = b.importExport(entries: doc.entries ?? [], folders: doc.folders ?? [],
                                   macros: doc.macros ?? [],
                                   credentialProfiles: doc.credentialProfiles ?? [])

        XCTAssertEqual(added.profiles, 1)
        let restored = try XCTUnwrap(b.entries.first)
        XCTAssertEqual(restored.credentialProfileID, profile.id,
                       "the reference must survive, under the same id")
        XCTAssertEqual(source(restored, profileHasPassword: true), .assignedProfile,
                       "the restored host must be able to use the profile once its password is set")
    }

    func testTheSecretItselfNeverTravels() throws {
        // The profile definition goes; the password stays in the Keychain.
        // Asserted on the encoded bytes rather than the model, because this is
        // the artifact that ends up in a repo.
        let profile = CredentialProfile(name: "Ops", user: "opsuser",
                                        identityFile: "~/.ssh/id_ed25519")
        var web = host("web-01")
        web.credentialProfileID = profile.id
        web.savePassword = true

        let data = try LibraryTransfer.encodeSessions(
            entries: [web], folders: [], credentialProfiles: [profile]
        )
        let json = try XCTUnwrap(String(data: data, encoding: .utf8)).lowercased()

        XCTAssertTrue(json.contains("opsuser"), "the definition travels")
        XCTAssertFalse(json.contains("password\":"), "no password field may appear in an export")
        XCTAssertFalse(json.contains("secret"))
    }

    // MARK: - Profile merge cases

    func testAProfileAlreadyHereIsLeftAlone() {
        // The local record may hold a Keychain secret the incoming definition
        // can't carry; overwriting it would be a pure loss.
        let store = SessionStore(fileURL: machineA)
        let local = CredentialProfile(name: "Ops", user: "localuser")
        store.upsert(local)
        let incoming = CredentialProfile(id: local.id, name: "Ops", user: "someone-else")

        let added = store.importExport(entries: [], folders: [], macros: [],
                                       credentialProfiles: [incoming])

        XCTAssertEqual(added.profiles, 0)
        XCTAssertEqual(store.credentialProfiles.count, 1)
        XCTAssertEqual(store.credentialProfiles.first?.user, "localuser",
                       "the local definition wins — it's the one with the password")
    }

    func testASameNamedProfileRemapsInsteadOfDuplicating() throws {
        // The library was rebuilt by hand here: "Ops" exists, just not as the
        // same record. Two identical-looking profiles where only one holds the
        // password is worse than merging.
        let store = SessionStore(fileURL: machineA)
        let local = CredentialProfile(name: "Ops", user: "opsuser")
        store.upsert(local)

        let foreign = CredentialProfile(name: "  ops  ", user: "opsuser")
        var web = host("web-01")
        web.credentialProfileID = foreign.id
        web.savePassword = true

        let added = store.importExport(entries: [web], folders: [], macros: [],
                                       credentialProfiles: [foreign])

        XCTAssertEqual(added.profiles, 0, "no second Ops")
        XCTAssertEqual(store.credentialProfiles.count, 1)
        let imported = try XCTUnwrap(store.entries.first)
        XCTAssertEqual(imported.credentialProfileID, local.id,
                       "the host must point at the local Ops, which is the one with the password")
        XCTAssertEqual(source(imported, profileHasPassword: true), .assignedProfile)
    }

    func testAGenuinelyNewProfileKeepsItsIdSoLaterImportsLineUp() {
        let store = SessionStore(fileURL: machineA)
        let incoming = CredentialProfile(name: "Staging", user: "deploy")

        store.importExport(entries: [], folders: [], macros: [], credentialProfiles: [incoming])

        XCTAssertEqual(store.credentialProfiles.first?.id, incoming.id,
                       "keeping the id makes a re-import match by id instead of drifting")
    }

    func testProfilesMergeBeforeEntriesAreWalked() throws {
        // Ordering is the whole trick: the credential policy asks whether an
        // entry's profile resolves locally, so a profile arriving in the same
        // file has to be in place before the entries are processed.
        let store = SessionStore(fileURL: machineA)
        let profile = CredentialProfile(name: "Ops", user: "opsuser")
        var web = host("web-01")
        web.credentialProfileID = profile.id
        web.savePassword = true

        store.importExport(entries: [web], folders: [], macros: [], credentialProfiles: [profile])

        let imported = try XCTUnwrap(store.entries.first)
        XCTAssertEqual(imported.credentialProfileID, profile.id,
                       "merging profiles after entries would have cleared this reference")
        XCTAssertTrue(imported.savePassword)
    }

    func testAnEntryWhoseProfileIsNotInTheFileStillClearsCleanly() throws {
        // Unchanged behaviour, and the reason it matters: without clearing,
        // the host falls through the resolver chain to *this* machine's
        // default credential.
        let store = SessionStore(fileURL: machineA)
        var web = host("web-01")
        web.credentialProfileID = UUID()
        web.savePassword = true

        store.importExport(entries: [web], folders: [], macros: [], credentialProfiles: [])

        let imported = try XCTUnwrap(store.entries.first)
        XCTAssertNil(imported.credentialProfileID)
        XCTAssertFalse(imported.savePassword)
    }

    // MARK: - Diff-friendliness

    func testExportOrderIsStableRegardlessOfLibraryOrder() throws {
        // These files are headed for git. Insertion order means adding one
        // host can reshuffle the file and bury the real change in noise.
        let entries = [
            host("web-02", folder: "prod"),
            host("db-01", folder: "prod"),
            host("web-01", folder: "dev"),
        ]
        let forward = try LibraryTransfer.encodeSessions(
            entries: entries, folders: [], credentialProfiles: []
        )
        let reversed = try LibraryTransfer.encodeSessions(
            entries: entries.reversed(), folders: [], credentialProfiles: []
        )

        XCTAssertEqual(forward, reversed, "the same library must encode byte-identically")
    }

    func testSortIsTotalForHostsSharingAFolderAndName() {
        // Two entries can legitimately share folder and name; without a
        // tiebreak the sort isn't stable and the file churns anyway.
        var a = SessionEntry(name: "web", folder: "prod", hostname: "same.example.com")
        var b = SessionEntry(name: "web", folder: "prod", hostname: "same.example.com")
        a.id = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        b.id = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!

        XCTAssertEqual(LibraryTransfer.sortedForDiff([b, a]).map(\.id),
                       LibraryTransfer.sortedForDiff([a, b]).map(\.id))
    }

    func testFoldersAndMacrosAlsoExportInAStableOrder() throws {
        let one = try LibraryTransfer.encodeSessions(
            entries: [], folders: ["prod/web", "dev", "prod/db"], credentialProfiles: []
        )
        let two = try LibraryTransfer.encodeSessions(
            entries: [], folders: ["dev", "prod/db", "prod/web"], credentialProfiles: []
        )
        XCTAssertEqual(one, two)

        // Same macro records, two orders — ids are per-instance, so this has
        // to reorder the same values rather than build them twice.
        let restart = Macro(name: "restart", text: "systemctl restart nginx")
        let disk = Macro(name: "disk", text: "df -h")
        XCTAssertEqual(try LibraryTransfer.encodeMacros([restart, disk]),
                       try LibraryTransfer.encodeMacros([disk, restart]))
    }

    // MARK: - Backward compatibility

    func testAnOlderExportWithNoProfilesStillImports() throws {
        // Every export written before this change has no credentialProfiles
        // key at all.
        let legacy = """
        {"portsideExport":1,"kind":"sessions",
         "entries":[{"id":"\(UUID().uuidString)","name":"web-01","folder":"",
                     "hostname":"web-01.example.com","savePassword":false}],
         "folders":[]}
        """.data(using: .utf8)!

        let doc = try XCTUnwrap(LibraryTransfer.decode(legacy))
        XCTAssertNil(doc.credentialProfiles)

        let store = SessionStore(fileURL: machineA)
        let added = store.importExport(entries: doc.entries ?? [], folders: doc.folders ?? [],
                                       macros: doc.macros ?? [],
                                       credentialProfiles: doc.credentialProfiles ?? [])
        XCTAssertEqual(added.sessions, 1)
        XCTAssertEqual(added.profiles, 0)
    }
}
