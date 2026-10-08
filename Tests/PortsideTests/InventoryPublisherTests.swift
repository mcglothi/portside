import XCTest
@testable import Portside

/// Publishing's git half, against real repositories in a temp directory: a
/// bare "team" repo stands in for the forge.
final class InventoryPublisherTests: XCTestCase {
    private var root: URL!
    private var bare: URL { root.appendingPathComponent("team.git") }
    private var work: URL { root.appendingPathComponent("publish") }
    private var other: URL { root.appendingPathComponent("someone-else") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-pub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "--quiet", "--bare", "--initial-branch=main", bare.path])
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func git(_ args: [String], in dir: URL? = nil) throws -> String {
        try InventoryGit.run(["-c", "user.name=Test", "-c", "user.email=test@example.com",
                              "-c", "commit.gpgsign=false"] + args, in: dir)
    }

    private var source: InventorySource { InventorySource(name: "Team", remote: bare.path) }

    private func manifest(_ names: [String]) throws -> Data {
        try LibraryTransfer.encodeSessions(
            entries: names.map { SessionEntry(name: $0, folder: "", hostname: "\($0).example.com") },
            folders: [], credentialProfiles: [])
    }

    /// What the team's main branch holds right now.
    private func onMain() throws -> String {
        try git(["--git-dir", bare.path, "show", "main:portside.json"])
    }

    // Commits need an identity. Tests can't rely on whoever runs them having
    // one, so the publishing clone gets a local one — the same thing a user's
    // global config provides.
    private func giveIdentity() throws {
        try git(["config", "user.name", "Test"], in: work)
        try git(["config", "user.email", "test@example.com"], in: work)
        try git(["config", "commit.gpgsign", "false"], in: work)
    }

    private func publish(_ names: [String], mode: InventoryPublisher.Mode = .branch,
                         branch: String = "portside/test-1") throws -> InventoryPublisher.Result {
        try InventoryPublisher.fetch(source, into: work)
        try giveIdentity()
        return try InventoryPublisher.publish(source, manifest: try manifest(names), message: "Update hosts",
                                              mode: mode, branchName: branch, in: work)
    }

    func testFirstPublishToAnEmptyRepositoryCreatesItsBranch() throws {
        let r = try publish(["web01"])
        XCTAssertTrue(r.createdSourceBranch)
        XCTAssertEqual(r.branch, "main", "nothing to review against, so it goes straight onto main")
        XCTAssertNil(r.pullRequestURL)
        XCTAssertTrue(try onMain().contains("web01"))
    }

    /// The default: a branch for review, and the team's main untouched.
    func testBranchModeLeavesMainAlone() throws {
        _ = try publish(["web01"])
        let r = try publish(["web01", "web02"], branch: "portside/test-2")
        XCTAssertEqual(r.branch, "portside/test-2")
        XCTAssertFalse(r.createdSourceBranch)
        XCTAssertFalse(try onMain().contains("web02"), "main only changes when the PR is merged")
        let onBranch = try git(["--git-dir", bare.path, "show", "portside/test-2:portside.json"])
        XCTAssertTrue(onBranch.contains("web02"))
        XCTAssertEqual(InventoryPublisher.remoteManifest(source, in: work).map { String(decoding: $0, as: UTF8.self) }
                        .map { $0.contains("web02") }, false, "remoteManifest reads origin/main, not the branch")
    }

    func testDirectModeFastForwardsMain() throws {
        _ = try publish(["web01"])
        let r = try publish(["web01", "web02"], mode: .direct, branch: "portside/test-3")
        XCTAssertEqual(r.branch, "main")
        XCTAssertTrue(try onMain().contains("web02"))
    }

    /// A push the server refuses — a protected branch, a required review — is
    /// reported, never forced.
    func testRejectedPushIsReportedNotForced() throws {
        _ = try publish(["web01"])
        let hook = bare.appendingPathComponent("hooks/pre-receive")
        try "#!/bin/sh\necho 'protected branch: changes must go through review' >&2\nexit 1\n"
            .write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)

        XCTAssertThrowsError(try publish(["web01", "web02"], mode: .direct, branch: "portside/test-4")) { error in
            XCTAssertTrue("\(error)".contains("protected branch"), "\(error)")
        }
        XCTAssertFalse(try onMain().contains("web02"))
    }

    func testPublishingTheSameThingAgainSaysSo() throws {
        // The same bytes: a fresh manifest would carry fresh host ids.
        let data = try manifest(["web01"])
        try InventoryPublisher.fetch(source, into: work)
        try giveIdentity()
        _ = try InventoryPublisher.publish(source, manifest: data, message: "first", mode: .direct,
                                           branchName: "portside/test-5a", in: work)
        XCTAssertThrowsError(try InventoryPublisher.publish(source, manifest: data, message: "again", mode: .direct,
                                                            branchName: "portside/test-5", in: work)) { error in
            XCTAssertTrue("\(error)".contains("Nothing to publish"), "\(error)")
        }
    }

    /// Someone else's newer version is the starting point, not something to
    /// overwrite: the branch is cut from the latest main.
    func testBranchStartsFromTheLatestMain() throws {
        _ = try publish(["web01"])
        try git(["clone", "--quiet", bare.path, other.path])
        try manifest(["web01", "theirs"]).write(to: other.appendingPathComponent("portside.json"))
        try git(["commit", "--quiet", "-am", "theirs"], in: other)
        try git(["push", "--quiet", "origin", "main"], in: other)

        _ = try publish(["web01", "theirs", "mine"], mode: .direct, branch: "portside/test-6")
        let log = try git(["--git-dir", bare.path, "log", "--format=%s", "main"])
        XCTAssertEqual(log.split(separator: "\n").first, "Update hosts")
        XCTAssertTrue(log.contains("theirs"), "their commit is history, not overwritten")
    }

    func testSymlinkedManifestIsNotWrittenThrough() throws {
        _ = try publish(["web01"])
        try git(["clone", "--quiet", bare.path, other.path])
        try FileManager.default.removeItem(at: other.appendingPathComponent("portside.json"))
        try FileManager.default.createSymbolicLink(atPath: other.appendingPathComponent("portside.json").path,
                                                   withDestinationPath: "/tmp/elsewhere.json")
        try git(["add", "-A"], in: other)
        try git(["commit", "--quiet", "-m", "symlink"], in: other)
        try git(["push", "--quiet", "origin", "main"], in: other)

        XCTAssertThrowsError(try publish(["web01", "web02"], mode: .direct, branch: "portside/test-7")) { error in
            XCTAssertTrue("\(error)".contains("symlink"), "\(error)")
        }
    }

    // MARK: - Pull request links

    func testPullRequestLinkComesFromTheForgesOwnPushOutput() {
        let github = """
            remote:
            remote: Create a pull request for 'portside/tim-1' on GitHub by visiting:
            remote:      https://github.com/acme/inventory/pull/new/portside/tim-1
            remote:
            """
        XCTAssertEqual(InventoryPublisher.pullRequestURL(fromPushOutput: github, remote: "x", base: "main",
                                                         head: "portside/tim-1")?.absoluteString,
                       "https://github.com/acme/inventory/pull/new/portside/tim-1")
        let gitlab = """
            remote: To create a merge request for portside/tim-1, visit:
            remote:   https://gitlab.example.com/ops/inventory/-/merge_requests/new?merge_request%5Bsource_branch%5D=portside%2Ftim-1
            """
        XCTAssertTrue(InventoryPublisher.pullRequestURL(fromPushOutput: gitlab, remote: "x", base: "main",
                                                        head: "portside/tim-1")?.absoluteString
                        .contains("merge_requests/new") == true)
    }

    func testGitHubCompareLinkWhenThePushSaysNothing() {
        for remote in ["git@github.com:acme/inventory.git", "https://github.com/acme/inventory",
                       "ssh://git@github.com/acme/inventory.git"] {
            XCTAssertEqual(InventoryPublisher.githubRepo(remote), "acme/inventory", remote)
        }
        XCTAssertEqual(InventoryPublisher.pullRequestURL(fromPushOutput: "", remote: "git@github.com:acme/inventory.git",
                                                         base: "main", head: "portside/tim-1")?.absoluteString,
                       "https://github.com/acme/inventory/compare/main...portside/tim-1?quick_pull=1")
        XCTAssertNil(InventoryPublisher.pullRequestURL(fromPushOutput: "", remote: "/srv/git/inv.git",
                                                       base: "main", head: "b"))
    }

    func testBranchNamesAreSafeAndReadable() {
        var c = DateComponents()
        c.year = 2026; c.month = 10; c.day = 8; c.hour = 9; c.minute = 5
        let date = Calendar(identifier: .gregorian).date(from: c)!
        XCTAssertEqual(InventoryPublisher.branchName(user: "Tim McG!", date: date), "portside/timmcg-20261008-0905")
    }
}
