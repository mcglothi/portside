import Foundation
import XCTest
@testable import Portside

/// Local configuration still pointing at a key that is about to stop working.
///
/// Retiring changes the **host**; it does not change the pointer on this Mac
/// that tells ssh to offer the key. A host that no longer accepts the only key
/// its config offers is a host you cannot log into — so this is the check that
/// stands between a successful rotation and a lockout of the user's own making.
final class KeyRotationReferencesTests: XCTestCase {

    private let oldKey = PublicKey(
        path: "/Users/t/.ssh/id_rsa.pub", line: "ssh-rsa AAAAOLD t@mac",
        algorithm: "ssh-rsa", blob: "AAAAOLD", comment: "t@mac",
        fingerprint: "SHA256:old", bits: 4096)

    private func host(_ name: String, identity: String? = nil) -> SessionEntry {
        var e = SessionEntry(name: name)
        e.kind = .host
        e.hostname = "\(name).internal"
        e.identityFile = identity
        return e
    }

    private func profile(_ name: String, identity: String?) -> CredentialProfile {
        var p = CredentialProfile(name: name)
        p.identityFile = identity
        return p
    }

    private func defaults(identity: String?) -> ConnectionDefaults {
        var d = ConnectionDefaults()
        d.identityFile = identity
        return d
    }

    // MARK: - Finding them

    func testAHostPointingAtTheRetiredKeyIsFound() {
        let found = KeyRotationReferences.references(
            to: oldKey,
            hosts: [host("web1", identity: "/Users/t/.ssh/id_rsa"), host("web2")],
            profiles: [], defaults: defaults(identity: nil))

        XCTAssertEqual(found.map(\.label), ["web1"])
    }

    /// A profile stands for every host deferring to it, so it matters more than
    /// a single host does.
    func testAProfilePointingAtTheRetiredKeyIsFound() {
        let found = KeyRotationReferences.references(
            to: oldKey, hosts: [],
            profiles: [profile("Prod", identity: "/Users/t/.ssh/id_rsa"),
                       profile("Lab", identity: "/Users/t/.ssh/other")],
            defaults: defaults(identity: nil))

        XCTAssertEqual(found.map(\.label), ["Prod (credential profile)"])
    }

    func testTheLibraryDefaultIsFound() {
        let found = KeyRotationReferences.references(
            to: oldKey, hosts: [], profiles: [],
            defaults: defaults(identity: "/Users/t/.ssh/id_rsa"))

        XCTAssertEqual(found.map(\.label), ["Library default key"])
    }

    // MARK: - Matching the path

    /// `identityFile` is the **private** key path and a `PublicKey` knows its
    /// `.pub`, so the two have to be normalised before they can be compared at
    /// all. Getting this wrong means never warning anyone.
    func testAPrivateKeyPathMatchesItsPublicKey() {
        XCTAssertTrue(KeyRotationReferences.names(oldKey, "/Users/t/.ssh/id_rsa"))
    }

    /// A profile pointing straight at the `.pub` is tolerated elsewhere in the
    /// app, so it has to be recognised here too.
    func testAPathPointingAtThePubAlsoMatches() {
        XCTAssertTrue(KeyRotationReferences.names(oldKey, "/Users/t/.ssh/id_rsa.pub"))
    }

    func testATildePathMatches() {
        let home = NSHomeDirectory()
        let key = PublicKey(path: "\(home)/.ssh/rotate_me.pub", line: "ssh-ed25519 AAAA t@n",
                            algorithm: "ssh-ed25519", blob: "AAAA", comment: "t@n",
                            fingerprint: "SHA256:x", bits: 256)
        XCTAssertTrue(KeyRotationReferences.names(key, "~/.ssh/rotate_me"))
    }

    func testADifferentKeyDoesNotMatch() {
        XCTAssertFalse(KeyRotationReferences.names(oldKey, "/Users/t/.ssh/id_ed25519"))
    }

    /// A path that merely *starts* with the key's path is a different file —
    /// `id_rsa_old` is not `id_rsa`.
    func testASimilarlyNamedKeyDoesNotMatch() {
        XCTAssertFalse(KeyRotationReferences.names(oldKey, "/Users/t/.ssh/id_rsa_old"))
        XCTAssertFalse(KeyRotationReferences.names(oldKey, "/Users/t/.ssh/id_rsa2"))
    }

    func testAnEmptyOrBlankPathMatchesNothing() {
        XCTAssertFalse(KeyRotationReferences.names(oldKey, ""))
        XCTAssertFalse(KeyRotationReferences.names(oldKey, "   "))
    }

    /// Redundant path components must not defeat the comparison.
    func testAnUntidyPathStillMatches() {
        XCTAssertTrue(KeyRotationReferences.names(oldKey, "/Users/t/.ssh/./id_rsa"))
        XCTAssertTrue(KeyRotationReferences.names(oldKey, "/Users/t/.ssh/sub/../id_rsa"))
    }

    // MARK: - Nothing to say

    func testNothingIsReportedWhenNoLocalConfigNamesTheKey() {
        let found = KeyRotationReferences.references(
            to: oldKey,
            hosts: [host("web1", identity: "/Users/t/.ssh/id_ed25519"), host("web2")],
            profiles: [profile("Prod", identity: nil)],
            defaults: defaults(identity: nil))

        XCTAssertTrue(found.isEmpty)
    }

    /// The caveat is shown regardless, because "Portside found nothing" is not
    /// "nothing names this key" — an aliased host's `IdentityFile` lives in
    /// `~/.ssh/config`, which Portside never reads, and aliased hosts are the
    /// common case in a real library.
    func testTheSSHConfigCaveatNamesTheFileItCannotSee() {
        XCTAssertTrue(KeyRotationReferences.sshConfigCaveat.contains("~/.ssh/config"))
        XCTAssertTrue(KeyRotationReferences.sshConfigCaveat.contains("IdentityFile"))
    }

    /// All three sources at once, in a stable order — hosts, then profiles,
    /// then the default — so the message doesn't reshuffle between openings.
    func testEverySourceIsReportedInAStableOrder() {
        let found = KeyRotationReferences.references(
            to: oldKey,
            hosts: [host("web1", identity: "~/.ssh/id_rsa")].map { entry -> SessionEntry in
                var e = entry
                e.identityFile = "/Users/t/.ssh/id_rsa"
                return e
            },
            profiles: [profile("Prod", identity: "/Users/t/.ssh/id_rsa")],
            defaults: defaults(identity: "/Users/t/.ssh/id_rsa"))

        XCTAssertEqual(found.map(\.label),
                       ["web1", "Prod (credential profile)", "Library default key"])
    }
}
