import Foundation
import XCTest
@testable import Portside

private func entry(_ name: String, kind: SessionKind = .host,
                   protected: Bool = false, local: Bool = false) -> SessionEntry {
    var e = SessionEntry(name: name)
    e.kind = kind
    e.isProtected = protected
    if !local { e.hostname = "\(name).internal" }
    return e
}

final class KeyDistributionPlanTests: XCTestCase {

    // MARK: - Candidates

    /// Only things with an `authorized_keys` to write to.
    func testOnlySSHHostsAreCandidates() {
        let entries = [
            entry("web"),
            entry("console", kind: .serial),
            entry("switch", kind: .telnet),
            entry("box", kind: .container, local: true),
            entry("pod", kind: .kubernetes, local: true),
        ]
        XCTAssertEqual(KeyDistributionPlan.candidates(from: entries).map(\.name), ["web"])
    }

    /// A container reached over ssh is still a host to write to; only the
    /// local-transport ones are excluded.
    func testRemoteContainersAreNotCandidatesButRemoteHostsAre() {
        var remoteContainer = entry("c", kind: .container)
        remoteContainer.hostname = "docker.internal"
        XCTAssertFalse(remoteContainer.usesLocalTransport)
        // Still excluded: the key belongs on the host, not inside the container.
        XCTAssertEqual(KeyDistributionPlan.candidates(from: [remoteContainer]).count, 0)
    }

    // MARK: - The protected-host rule

    /// **The rule that matters.** "Select All" is how someone ends up pushing
    /// to the production box they deliberately fenced off.
    func testSelectAllNeverSweepsInAProtectedHost() {
        let hosts = [entry("a"), entry("prod", protected: true), entry("b")]
        var plan = KeyDistributionPlan(candidates: hosts)
        plan.selectAll()
        XCTAssertEqual(Set(plan.selectedEntries.map(\.name)), ["a", "b"])
        XCTAssertTrue(plan.protectedSelected.isEmpty)
    }

    /// Protected means "has to be a decision", not "impossible".
    func testAProtectedHostCanStillBeTickedByHand() {
        let prod = entry("prod", protected: true)
        var plan = KeyDistributionPlan(candidates: [prod])
        plan.toggle(prod)
        XCTAssertEqual(plan.selectedEntries.map(\.name), ["prod"])
        XCTAssertEqual(plan.protectedSelected.map(\.name), ["prod"])
    }

    /// Select All adds; it must not quietly drop a protected host the user
    /// had already chosen on purpose.
    func testSelectAllPreservesAProtectedHostAlreadyChosen() {
        let hosts = [entry("a"), entry("prod", protected: true)]
        var plan = KeyDistributionPlan(candidates: hosts)
        plan.toggle(hosts[1])
        plan.selectAll()
        XCTAssertEqual(Set(plan.selectedEntries.map(\.name)), ["a", "prod"])
    }

    func testSelectNoneClearsEverythingIncludingProtected() {
        let hosts = [entry("a"), entry("prod", protected: true)]
        var plan = KeyDistributionPlan(candidates: hosts)
        plan.selectAll()
        plan.toggle(hosts[1])
        plan.selectNone()
        XCTAssertTrue(plan.isEmpty)
    }

    // MARK: - Selection bookkeeping

    func testToggleFlipsBothWays() {
        let a = entry("a")
        var plan = KeyDistributionPlan(candidates: [a])
        XCTAssertFalse(plan.isSelected(a))
        plan.toggle(a)
        XCTAssertTrue(plan.isSelected(a))
        plan.toggle(a)
        XCTAssertFalse(plan.isSelected(a))
    }

    /// A preselection from the sidebar may name hosts that aren't candidates
    /// (a serial console, or an entry deleted since). Those must not survive
    /// into a push as ids with nothing behind them.
    func testPreselectionIsFilteredToActualCandidates() {
        let a = entry("a")
        let ghost = UUID()
        let plan = KeyDistributionPlan(candidates: [a], selected: [a.id, ghost])
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan.selectedEntries.map(\.name), ["a"])
    }

    func testSelectedEntriesFollowCandidateOrderNotSelectionOrder() {
        let hosts = [entry("a"), entry("b"), entry("c")]
        var plan = KeyDistributionPlan(candidates: hosts)
        plan.toggle(hosts[2])
        plan.toggle(hosts[0])
        XCTAssertEqual(plan.selectedEntries.map(\.name), ["a", "c"])
    }

    func testSummaryCountsHostsAndSingularises() {
        let hosts = [entry("a"), entry("b")]
        var plan = KeyDistributionPlan(candidates: hosts)
        plan.toggle(hosts[0])
        XCTAssertEqual(plan.summary(keyName: "id_ed25519.pub"), "Add id_ed25519.pub to 1 host")
        plan.toggle(hosts[1])
        XCTAssertEqual(plan.summary(keyName: "id_ed25519.pub"), "Add id_ed25519.pub to 2 hosts")
    }
}

// MARK: - Key parsing

final class PublicKeyTests: XCTestCase {

    func testParsesAKeyWithAComment() {
        let key = PublicKey.parse(
            line: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI tim@newton",
            path: "/x/id_ed25519.pub", fingerprint: "SHA256:abc", bits: 256)
        XCTAssertEqual(key?.algorithm, "ssh-ed25519")
        XCTAssertEqual(key?.blob, "AAAAC3NzaC1lZDI1NTE5AAAAI")
        XCTAssertEqual(key?.comment, "tim@newton")
        XCTAssertEqual(key?.shortAlgorithm, "ED25519")
    }

    func testParsesAKeyWithNoComment() {
        let key = PublicKey.parse(line: "ssh-rsa AAAAB3Nza", path: "/x.pub",
                                  fingerprint: "SHA256:abc", bits: 2048)
        XCTAssertEqual(key?.comment, "")
        XCTAssertEqual(key?.shortAlgorithm, "RSA")
    }

    /// A comment can contain spaces and must survive whole.
    func testCommentKeepsItsSpaces() {
        let key = PublicKey.parse(line: "ssh-ed25519 AAAAC3 work laptop 2026",
                                  path: "/x.pub", fingerprint: "f", bits: nil)
        XCTAssertEqual(key?.comment, "work laptop 2026")
    }

    /// Being handed a private key must fail closed, not produce something
    /// pushable.
    func testPrivateKeyMaterialIsRejected() {
        XCTAssertNil(PublicKey.parse(line: "-----BEGIN OPENSSH PRIVATE KEY-----",
                                     path: "/x", fingerprint: "f", bits: nil))
    }

    func testJunkIsRejected() {
        for line in ["", "   ", "# a comment", "hello world",
                     "notakey AAAAB3", "ssh-ed25519", "ssh-ed25519 not!valid!base64"] {
            XCTAssertNil(PublicKey.parse(line: line, path: "/x", fingerprint: "f", bits: nil),
                         "should have rejected: \(line)")
        }
    }

    /// Identity is type + blob. The comment is decoration and must not be part
    /// of the "does this host already have it" comparison.
    func testIdentityFieldsIgnoreTheComment() {
        let a = PublicKey.parse(line: "ssh-ed25519 AAAAC3 tim@newton",
                                path: "/a.pub", fingerprint: "f", bits: nil)
        let b = PublicKey.parse(line: "ssh-ed25519 AAAAC3 someone@else",
                                path: "/b.pub", fingerprint: "f", bits: nil)
        XCTAssertEqual(a?.identityFields, b?.identityFields)
    }

    func testFingerprintParsing() {
        let parsed = PublicKey.parseFingerprint(
            "256 SHA256:9kQr0/abcDEF+ghi tim@newton (ED25519)")
        XCTAssertEqual(parsed?.fingerprint, "SHA256:9kQr0/abcDEF+ghi")
        XCTAssertEqual(parsed?.bits, 256)
    }

    /// A comment containing spaces must not shift the fields.
    func testFingerprintParsingWithASpacedComment() {
        let parsed = PublicKey.parseFingerprint("2048 SHA256:abc my work key (RSA)")
        XCTAssertEqual(parsed?.fingerprint, "SHA256:abc")
        XCTAssertEqual(parsed?.bits, 2048)
    }

    func testFingerprintParsingRejectsJunk() {
        XCTAssertNil(PublicKey.parseFingerprint(""))
        XCTAssertNil(PublicKey.parseFingerprint("no such file"))
    }
}

// MARK: - Discovery

final class PublicKeyLocatorTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-keys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ name: String, _ contents: String) throws {
        try contents.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// **Private keys must never be offered.** They sit next to public ones
    /// under near-identical names, and this is the whole reason discovery reads
    /// only `.pub`.
    func testPrivateKeysAreNeverDiscovered() async throws {
        try write("id_ed25519", "-----BEGIN OPENSSH PRIVATE KEY-----\nsecret\n")
        try write("id_ed25519.pub", "ssh-ed25519 AAAAC3PUB tim@newton\n")
        let keys = await PublicKeyLocator.discover(in: dir.path,
                                                   fingerprinter: { _ in ("SHA256:x", 256) })
        XCTAssertEqual(keys.map(\.filename), ["id_ed25519.pub"])
    }

    func testNonKeyFilesAreIgnored() async throws {
        try write("config", "Host *\n")
        try write("known_hosts", "example.com ssh-rsa AAAA\n")
        try write("id_rsa.pub", "ssh-rsa AAAAB3 tim@newton\n")
        let keys = await PublicKeyLocator.discover(in: dir.path,
                                                   fingerprinter: { _ in ("SHA256:x", 2048) })
        XCTAssertEqual(keys.map(\.filename), ["id_rsa.pub"])
    }

    /// ed25519 first — the default OpenSSH generates, and usually the one meant.
    func testKeysAreOrderedByPreference() async throws {
        try write("id_rsa.pub", "ssh-rsa AAAAB3 a\n")
        try write("id_ed25519.pub", "ssh-ed25519 AAAAC3 b\n")
        try write("id_ecdsa.pub", "ecdsa-sha2-nistp256 AAAAE2 c\n")
        let keys = await PublicKeyLocator.discover(in: dir.path,
                                                   fingerprinter: { _ in ("SHA256:x", nil) })
        XCTAssertEqual(keys.map(\.shortAlgorithm), ["ED25519", "ECDSA", "RSA"])
    }

    func testAMissingDirectoryIsEmptyNotACrash() async {
        let keys = await PublicKeyLocator.discover(in: "/nope/does/not/exist",
                                                   fingerprinter: { _ in nil })
        XCTAssertTrue(keys.isEmpty)
    }

    /// A key still lists when `ssh-keygen` can't fingerprint it — it just shows
    /// no fingerprint, rather than vanishing with no explanation.
    func testAKeyWithoutAFingerprintStillLists() async throws {
        try write("id_ed25519.pub", "ssh-ed25519 AAAAC3 tim@newton\n")
        let keys = await PublicKeyLocator.discover(in: dir.path, fingerprinter: { _ in nil })
        XCTAssertEqual(keys.count, 1)
        XCTAssertEqual(keys.first?.fingerprint, "")
    }
}
