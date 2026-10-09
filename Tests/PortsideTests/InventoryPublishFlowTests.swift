import XCTest
@testable import Portside

/// Publishing end to end through the store: a linked folder, a bare "team"
/// repository standing in for the forge, and a second clone standing in for a
/// teammate.
@MainActor
final class InventoryPublishFlowTests: XCTestCase {
    private var root: URL!
    private var bare: URL { root.appendingPathComponent("team.git") }
    private var teammate: URL { root.appendingPathComponent("teammate") }
    private var store: SessionStore!

    override func setUp() async throws {
        root = URL(fileURLWithPath: "/tmp/ppf-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "--quiet", "--bare", "--initial-branch=main", bare.path])
        store = SessionStore(fileURL: root.appendingPathComponent("lib/portside.json"))
    }

    override func tearDown() async throws {
        store = nil
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func git(_ args: [String], in dir: URL? = nil) throws -> String {
        try InventoryGit.run(["-c", "user.name=Teammate", "-c", "user.email=mate@example.com",
                              "-c", "commit.gpgsign=false"] + args, in: dir)
    }

    private func host(_ name: String, folder: String = "team") -> SessionEntry {
        SessionEntry(name: name, folder: folder, hostname: "\(name).example.com")
    }

    private func onBranch(_ branch: String) throws -> SharedManifest.Parsed {
        try SharedManifest.parseKeepingIDs(Data(try git(["--git-dir", bare.path, "show", "\(branch):portside.json"]).utf8))
    }

    /// The teammate edits main directly, the way a merged PR would.
    private func teammateEdits(_ change: (inout [SessionEntry]) -> Void) throws {
        if !FileManager.default.fileExists(atPath: teammate.path) {
            try git(["clone", "--quiet", bare.path, teammate.path])
        } else {
            try git(["pull", "--quiet", "--ff-only"], in: teammate)
        }
        let file = teammate.appendingPathComponent("portside.json")
        var parsed = try SharedManifest.parseKeepingIDs(Data(contentsOf: file))
        change(&parsed.entries)
        try LibraryTransfer.encodeSessions(entries: parsed.entries, folders: parsed.folders,
                                           credentialProfiles: []).write(to: file)
        try git(["commit", "--quiet", "-am", "teammate"], in: teammate)
        try git(["push", "--quiet", "origin", "main"], in: teammate)
    }

    private func create(_ names: [String]) async throws -> InventorySource {
        for n in names { store.upsert(host(n)) }
        let src = InventorySource(name: "Team", remote: bare.path)
        let r = await store.createSharedInventory(src, fromFolder: "team")
        guard case .success(let result) = r else { throw XCTSkip("create failed: \(r)") }
        XCTAssertTrue(result.createdSourceBranch)
        return src
    }

    private func publish(_ src: InventorySource, resolutions: [UUID: InventoryPublishing.Side] = [:])
        async throws -> InventoryPublisher.Result {
        guard case .success(let plan) = await store.planPublish(sourceID: src.id) else {
            XCTFail("plan failed"); throw XCTSkip()
        }
        let r = await store.publish(plan, resolutions: resolutions, message: "test publish")
        switch r {
        case .success(let result): return result
        case .failure(let f): XCTFail(f.message); throw XCTSkip(f.message)
        }
    }

    // MARK: -

    func testCreateFromAFolderPublishesAndSubscribes() async throws {
        let src = try await create(["web01", "web02"])
        XCTAssertEqual(try onBranch("main").entries.map(\.name).sorted(), ["web01", "web02"])
        XCTAssertEqual(store.sharedEntries(inSource: src.id).map(\.name).sorted(), ["web01", "web02"],
                       "the team's view shows what's merged")
        XCTAssertNotNil(store.publishLink(forSource: src.id))
    }

    func testRepositoryThatAlreadyHasAnInventoryIsNotOverwritten() async throws {
        _ = try await create(["web01"])
        let other = SessionStore(fileURL: root.appendingPathComponent("lib2/portside.json"))
        other.upsert(host("mine"))
        let r = await other.createSharedInventory(InventorySource(name: "Team", remote: bare.path), fromFolder: "team")
        guard case .failure(let f) = r else { return XCTFail("overwrote the team's inventory") }
        XCTAssertTrue(f.message.contains("already has an inventory"), f.message)
        XCTAssertEqual(try onBranch("main").entries.map(\.name), ["web01"])
    }

    /// Different hosts changed on each side: both land, and the folder takes
    /// in the teammate's change.
    func testTeammateChangesMergeAndComeIntoTheFolder() async throws {
        let src = try await create(["web01", "web02"])
        store.setDirectPush(true, forSource: src.id)
        try teammateEdits { hosts in
            if let i = hosts.firstIndex(where: { $0.name == "web02" }) { hosts[i].port = 2222 }
        }
        var mine = try XCTUnwrap(store.entries.first { $0.name == "web01" })
        mine.user = "deploy"
        store.upsert(mine)

        let r = try await publish(src)
        XCTAssertEqual(r.branch, "main")
        let main = try onBranch("main")
        XCTAssertEqual(main.entries.first { $0.name == "web01" }?.user, "deploy")
        XCTAssertEqual(main.entries.first { $0.name == "web02" }?.port, 2222, "their change survived")
        XCTAssertEqual(store.entries.first { $0.name == "web02" }?.port, 2222, "and came into my folder")
    }

    /// A teammate's change to a shared container — which container, which
    /// shell — comes into the linked folder like a host's address does, and
    /// the next publish doesn't put the old one back.
    func testTeammateContainerChangeComesIntoTheFolder() async throws {
        var box = host("plex")
        box.kind = .container
        box.container = ContainerTarget(engine: .docker, name: "plex-1", shell: "sh")
        store.upsert(box)
        let src = try await create(["web01"])
        store.setDirectPush(true, forSource: src.id)
        try teammateEdits { hosts in
            if let i = hosts.firstIndex(where: { $0.name == "plex" }) {
                hosts[i].container = ContainerTarget(engine: .podman, name: "plex-2", shell: "bash")
            }
        }
        var mine = try XCTUnwrap(store.entries.first { $0.name == "web01" })
        mine.user = "deploy"
        store.upsert(mine)

        _ = try await publish(src)
        let local = try XCTUnwrap(store.entries.first { $0.name == "plex" })
        XCTAssertEqual(local.kind, .container)
        XCTAssertEqual(local.container, ContainerTarget(engine: .podman, name: "plex-2", shell: "bash"),
                       "the teammate's container came into my folder")

        mine.user = "ops"
        store.upsert(mine)
        _ = try await publish(src)
        XCTAssertEqual(try onBranch("main").entries.first { $0.name == "plex" }?.container?.name, "plex-2",
                       "a second publish kept their change rather than reverting it")
    }

    func testSameHostEditedOnBothSidesIsAConflictToChoose() async throws {
        let src = try await create(["web01"])
        store.setDirectPush(true, forSource: src.id)
        try teammateEdits { hosts in hosts[0].user = "theirs" }
        var mine = try XCTUnwrap(store.entries.first { $0.name == "web01" })
        mine.user = "mine"
        store.upsert(mine)

        guard case .success(let plan) = await store.planPublish(sourceID: src.id) else { return XCTFail() }
        let conflict = try XCTUnwrap(plan.merged().conflicts.first)
        guard case .failure = await store.publish(plan, message: "x") else {
            return XCTFail("published with a conflict unanswered")
        }
        _ = try await publish(src, resolutions: [conflict.id: .mine])
        XCTAssertEqual(try onBranch("main").entries.first?.user, "mine")
    }

    /// The base rule. A change waiting in an unmerged PR must not be read, on
    /// the next publish, as the team removing it.
    func testSecondPublishKeepsAChangeStillInReview() async throws {
        let src = try await create(["web01", "web02"])
        // Default mode: review branches.
        var a = try XCTUnwrap(store.entries.first { $0.name == "web01" })
        a.user = "first-change"
        store.upsert(a)
        let first = try await publish(src)
        XCTAssertNotEqual(first.branch, "main")
        XCTAssertNil(try onBranch("main").entries.first { $0.name == "web01" }?.user, "main untouched until merged")

        var b = try XCTUnwrap(store.entries.first { $0.name == "web02" })
        b.user = "second-change"
        store.upsert(b)
        // Distinct branch names need a different minute; name it explicitly.
        guard case .success(let plan) = await store.planPublish(sourceID: src.id) else { return XCTFail() }
        let merged = plan.merged().hosts
        XCTAssertEqual(merged.first { $0.name == "web01" }?.user, "first-change",
                       "the unmerged first change is still in what's proposed")
        XCTAssertEqual(merged.first { $0.name == "web02" }?.user, "second-change")
        XCTAssertEqual(store.entries.first { $0.name == "web01" }?.user, "first-change",
                       "and the folder never lost it")
    }

    func testLinkingAnExistingInventoryAdoptsItsHosts() async throws {
        let src = try await create(["web01", "db01"])
        let colleague = SessionStore(fileURL: root.appendingPathComponent("lib3/portside.json"))
        XCTAssertNil(colleague.addInventorySource(src))
        await colleague.refreshInventorySource(id: src.id)
        let failure = await colleague.linkFolderForPublishing(sourceID: src.id, folder: "platform")
        XCTAssertNil(failure)
        XCTAssertEqual(colleague.entriesInFolder("platform").map(\.name).sorted(), ["db01", "web01"])

        // An edit there publishes as a change to the same host, not a new one.
        var e = try XCTUnwrap(colleague.entries.first { $0.name == "db01" })
        e.port = 5433
        colleague.upsert(e)
        colleague.setDirectPush(true, forSource: src.id)
        guard case .success(let plan) = await colleague.planPublish(sourceID: src.id) else { return XCTFail() }
        XCTAssertEqual(plan.changes().map(\.kind), [.changed])
        guard case .success = await colleague.publish(plan, message: "port") else { return XCTFail() }
        let main = try onBranch("main")
        XCTAssertEqual(main.entries.count, 2)
        XCTAssertEqual(main.entries.first { $0.name == "db01" }?.port, 5433)
    }

    func testSecretsBlockThePublish() async throws {
        let src = try await create(["web01"])
        // A valid host that would publish — the token is only in its name.
        var leaky = host("db")
        leaky.name = "db ghp_0123456789abcdefghijABCDEFGHIJ"
        store.upsert(leaky)
        guard case .success(let plan) = await store.planPublish(sourceID: src.id) else { return XCTFail() }
        XCTAssertFalse(plan.secrets.isEmpty)
        guard case .failure(let f) = await store.publish(plan, message: "x") else { return XCTFail("committed a token") }
        XCTAssertTrue(f.message.contains("GitHub token"), f.message)
        XCTAssertFalse(try onBranch("main").entries.contains { $0.name.contains("ghp_") })
    }

    func testTeamRemovalReachesTheFolderAndCanBeUndone() async throws {
        let src = try await create(["web01", "old"])
        store.setDirectPush(true, forSource: src.id)
        try teammateEdits { hosts in hosts.removeAll { $0.name == "old" } }
        store.upsert(host("new"))
        _ = try await publish(src)
        XCTAssertNil(store.entries.first { $0.name == "old" }, "the team removed it and I hadn't touched it")
        XCTAssertNotNil(store.undoLastDelete(), "but it went through the undoable delete")
    }
}
