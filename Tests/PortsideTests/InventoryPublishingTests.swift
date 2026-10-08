import XCTest
@testable import Portside

/// Publishing's pure core: what a linked folder turns into, how it merges with
/// what the team already has, and what is never committed.
final class InventoryPublishingTests: XCTestCase {
    private func host(_ name: String, folder: String = "team", id: UUID = UUID(), user: String? = nil) -> SessionEntry {
        var e = SessionEntry(name: name, folder: folder, hostname: "\(name).example.com")
        e.id = id
        e.user = user
        return e
    }

    // MARK: - Prepare

    func testPreparePublishesOnlyTheLinkedSubtreeWithRelativeFolders() {
        let entries = [host("a", folder: "team"), host("b", folder: "team/web"),
                       host("mine", folder: "personal"), host("c", folder: "teamish")]
        let p = InventoryPublishing.prepare(entries: entries, folders: ["team/db", "personal"], root: "team")
        XCTAssertEqual(p.hosts.map(\.name), ["a", "b"], "only team/ and beneath — not teamish/, not personal/")
        XCTAssertEqual(p.hosts.first { $0.name == "b" }?.folder, "web")
        XCTAssertEqual(p.hosts.first { $0.name == "a" }?.folder, "")
        XCTAssertEqual(p.folders, ["db"])
    }

    /// The file in git is exactly what subscribers would keep — and the
    /// review says what was left out.
    func testPrepareStripsPersonalFieldsAndSaysSo() throws {
        var e = host("web01")
        e.runOnConnect = "tmux attach"
        e.forwardAgent = true
        e.credentialProfileID = UUID()
        e.savePassword = true
        e.isFavorite = true
        var k = host("pod")
        k.kind = .kubernetes
        let p = InventoryPublishing.prepare(entries: [e, k], folders: [], root: "team")
        let out = try XCTUnwrap(p.hosts.first)
        XCTAssertNil(out.runOnConnect)
        XCTAssertNil(out.forwardAgent)
        XCTAssertNil(out.credentialProfileID)
        XCTAssertFalse(out.savePassword)
        XCTAssertFalse(out.isFavorite)
        XCTAssertEqual(out.id, e.id, "a local host publishes under its own id")
        let notes = Set(p.notes.map(\.text))
        XCTAssertTrue(notes.contains("run-on-connect left out"))
        XCTAssertTrue(notes.contains("credential profile left out"))
        XCTAssertTrue(p.notes.contains { $0.host == "pod" && $0.text.hasPrefix("not published") })
    }

    func testHostsFromTheSourceKeepTheirManifestIDs() {
        let local = host("web01")
        let manifestID = UUID()
        let p = InventoryPublishing.prepare(entries: [local], folders: [], root: "team",
                                            manifestIDs: [local.id: manifestID])
        XCTAssertEqual(p.hosts.first?.id, manifestID)
    }

    // MARK: - Merge

    func testOneSidedChangesMergeCleanly() {
        let id1 = UUID(), id2 = UUID(), id3 = UUID()
        let base = [host("a", id: id1), host("b", id: id2)]
        var mine = base
        mine[0].user = "deploy"                       // I changed a
        mine.append(host("new-mine", id: id3))        // I added one
        var theirs = base
        theirs[1].port = 2222                         // they changed b
        theirs.append(host("new-theirs"))             // they added one
        let m = InventoryPublishing.merge(base: base, mine: mine, theirs: theirs)
        XCTAssertTrue(m.conflicts.isEmpty)
        XCTAssertEqual(m.hosts.count, 4)
        XCTAssertEqual(m.hosts.first { $0.id == id1 }?.user, "deploy")
        XCTAssertEqual(m.hosts.first { $0.id == id2 }?.port, 2222)
    }

    /// A rename is a change to one host, not a delete and an add — the
    /// reason the merge is by id.
    func testRenameIsAChangeNotAReplacement() {
        let id = UUID()
        let base = [host("old-name", id: id)]
        var mine = base
        mine[0].name = "new-name"
        let m = InventoryPublishing.merge(base: base, mine: mine, theirs: base)
        XCTAssertEqual(m.hosts.map(\.name), ["new-name"])
        XCTAssertEqual(InventoryPublishing.changes(from: base, to: m.hosts).map(\.kind), [.changed])
    }

    func testRemovalsMergeAndDeleteVersusEditConflicts() {
        let keep = UUID(), gone = UUID(), contested = UUID()
        let base = [host("keep", id: keep), host("gone", id: gone), host("contested", id: contested)]
        var mine = base.filter { $0.id != gone }      // I removed "gone"
        mine.removeAll { $0.id == contested }          // and "contested"
        var theirs = base
        theirs[2].user = "root"                        // they edited "contested"
        let m = InventoryPublishing.merge(base: base, mine: mine, theirs: theirs)
        XCTAssertFalse(m.hosts.contains { $0.id == gone }, "a removal nobody else touched goes through")
        XCTAssertEqual(m.conflicts.map(\.id), [contested], "deleting what someone else edited is a conflict")
        XCTAssertNil(m.conflicts.first?.mine)
        XCTAssertEqual(m.hosts.first { $0.id == contested }?.user, "root", "unresolved means theirs")

        let resolved = InventoryPublishing.merge(base: base, mine: mine, theirs: theirs,
                                                 resolutions: [contested: .mine])
        XCTAssertFalse(resolved.hosts.contains { $0.id == contested }, "keeping mine keeps the deletion")
    }

    func testSameChangeOnBothSidesIsNoConflict() {
        let id = UUID()
        let base = [host("a", id: id)]
        var both = base
        both[0].port = 2200
        XCTAssertTrue(InventoryPublishing.merge(base: base, mine: both, theirs: both).conflicts.isEmpty)
        var other = base
        other[0].port = 2300
        XCTAssertEqual(InventoryPublishing.merge(base: base, mine: both, theirs: other).conflicts.count, 1)
    }

    func testFoldersMergeAsSets() {
        let m = InventoryPublishing.merge(base: [], mine: [], theirs: [],
                                          baseFolders: ["a", "b", "c"],
                                          mineFolders: ["a", "b", "mine"],       // removed c, added mine
                                          theirFolders: ["a", "c", "theirs"])    // removed b, added theirs
        XCTAssertEqual(m.folders, ["a", "mine", "theirs"])
    }

    /// A container on an SSH host publishes; one on this Mac is named in the
    /// review as staying behind, with the reason that fits it.
    func testPreparePublishesContainersOnSSHHostsOnly() throws {
        var remote = host("plex")
        remote.kind = .container
        remote.container = ContainerTarget(engine: .docker, name: "ix-plex-plex-1", shell: "bash")
        var local = host("redis")
        local.kind = .container
        local.hostname = ""
        local.container = ContainerTarget(engine: .docker, name: "redis-1")
        let p = InventoryPublishing.prepare(entries: [remote, local], folders: [], root: "team")
        XCTAssertEqual(p.hosts.map(\.name), ["plex"])
        XCTAssertEqual(p.hosts.first?.container, remote.container)
        let note = try XCTUnwrap(p.notes.first { $0.host == "redis" })
        XCTAssertTrue(note.text.contains("runs on this Mac"), note.text)
    }

    func testContainerChangesAreDescribedForReview() {
        let id = UUID()
        var before = host("plex", id: id)
        before.kind = .container
        before.container = ContainerTarget(engine: .docker, name: "plex-1", shell: "sh")
        var after = before
        after.container = ContainerTarget(engine: .podman, name: "plex-2", shell: "bash", user: "plex")
        let c = InventoryPublishing.changes(from: [before], to: [after])
        XCTAssertEqual(c.first?.fields.map(\.field), ["engine", "container", "shell", "container user"])
        XCTAssertEqual(c.first?.fields.first { $0.field == "container" }?.after, "plex-2")
    }

    func testChangesDescribeFieldsForReview() {
        let id = UUID()
        let before = [host("web01", id: id, user: "deploy")]
        var after = before
        after[0].user = "ops"
        after[0].environment = .prod
        let c = InventoryPublishing.changes(from: before, to: after)
        XCTAssertEqual(c.first?.fields.map(\.field), ["user", "environment"])
        XCTAssertEqual(c.first?.fields.first?.before, "deploy")
    }

    // MARK: - Secrets

    func testSecretsAreRefused() {
        let bad = [
            "https://admin:hunter2@db.example.com",
            "-----BEGIN OPENSSH PRIVATE KEY-----",
            "ghp_0123456789abcdefghijABCDEFGHIJ",
            "glpat-abcdefghij0123456789",
            "xoxb-1234567890-abcdefghij",
            "AKIAIOSFODNN7EXAMPLE",
            "db password: hunter2",
            "Zq8vN3kL0pR7tY2wX5cB9mJ4hF6gD1sA",
        ]
        for value in bad { XCTAssertNotNil(InventoryPublishing.secretReason(value), value) }
        let fine = ["web-01", "prod/web/eu-west", "~/.ssh/id_ed25519", "Platform Team — DB primary",
                    "password-reset-service", "https://wiki.example.com/hosts"]
        for value in fine { XCTAssertNil(InventoryPublishing.secretReason(value), value) }
    }

    func testFindingsNameTheHostAndField() {
        var e = host("db ghp_0123456789abcdefghijABCDEFGHIJ")
        e.identityFile = "~/.ssh/id_ed25519"
        let findings = InventoryPublishing.secretFindings(in: [e])
        XCTAssertEqual(findings.count, 1)
        XCTAssertTrue(findings[0].text.hasPrefix("name "))
    }

    // MARK: - The CI validator agrees with the app

    /// `Scripts/portside-inventory-check.py` reimplements the sanitizer and
    /// secret scan in Python so teams can run it in CI anywhere. Two
    /// implementations of one rule drift — so the same records go through
    /// both, and they must agree record by record.
    func testCIValidatorAgreesWithTheApp() throws {
        var records: [SessionEntry] = []
        func add(_ name: String, _ change: (inout SessionEntry) -> Void = { _ in }) {
            var e = SessionEntry(name: name, folder: "", hostname: "\(name).example.com")
            change(&e)
            records.append(e)
        }
        add("plain")
        add("option-host") { $0.hostname = "-oProxyCommand=x" }
        // Only the leading-dash rule refuses this one: every character is a
        // legal host character. Without it, a drift in that rule went unseen.
        add("dash-host") { $0.hostname = "-oops" }
        add("dash-alias") { $0.hostname = ""; $0.sshAlias = "-v" }
        add("space-host") { $0.hostname = "a b" }
        add("semicolon-alias") { $0.hostname = ""; $0.sshAlias = "a;b" }
        add("dash-user") { $0.user = "-l" }
        add("ad-user") { $0.user = "CORP\\tim" }
        add("ipv6") { $0.hostname = "fe80::1" }
        add("no-target") { $0.hostname = ""; $0.sshAlias = nil }
        add("container") { $0.kind = .container }
        add("ssh-container") {
            $0.kind = .container
            $0.container = ContainerTarget(engine: .docker, name: "web-1", shell: "/bin/bash", user: "app:1000")
        }
        add("local-container") {
            $0.kind = .container; $0.hostname = ""
            $0.container = ContainerTarget(engine: .docker, name: "web-1")
        }
        add("chained-container") {
            $0.kind = .container
            $0.container = ContainerTarget(engine: .docker, name: "web;id")
        }
        add("command-shell") {
            $0.kind = .container
            $0.container = ContainerTarget(engine: .docker, name: "web", shell: "sh -c id")
        }
        add("option-container-user") {
            $0.kind = .container
            $0.container = ContainerTarget(engine: .docker, name: "web", user: "-uroot")
        }
        add("serial") { $0.kind = .serial }
        add("db ghp_0123456789abcdefghijABCDEFGHIJ")
        add("folder-secret") { $0.folder = "https://admin:pw@host" }
        add("key-path") { $0.identityFile = "~/.ssh/id_ed25519" }
        add("random") { $0.name = "Zq8vN3kL0pR7tY2wX5cB9mJ4hF6gD1sA" }

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("check-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try LibraryTransfer.encodeSessions(entries: records, folders: [], credentialProfiles: []).write(to: file)

        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Scripts/portside-inventory-check.py")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path, "--json", file.path]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rows = try XCTUnwrap(report["hosts"] as? [[String: Any]])
        let python = Dictionary(uniqueKeysWithValues: rows.map {
            ($0["name"] as! String, ($0["verdict"] as! String, $0["secret"] as! Bool))
        })

        for e in records {
            let swiftKeeps = SharedManifest.sanitized(e, sourceID: UUID()) != nil
            let swiftSecret = !InventoryPublishing.secretFindings(in: [e]).isEmpty
            let (verdict, secret) = try XCTUnwrap(python[e.name], e.name)
            XCTAssertEqual(verdict == "keep", swiftKeeps, "\(e.name): app and CI validator disagree on keeping it")
            XCTAssertEqual(secret, swiftSecret, "\(e.name): app and CI validator disagree on a secret")
        }
        XCTAssertEqual(process.terminationStatus, 1, "errors make CI fail")
    }
}
