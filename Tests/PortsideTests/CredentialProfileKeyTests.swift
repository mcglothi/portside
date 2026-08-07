import Foundation
import XCTest
@testable import Portside

final class CredentialProfileKeyTests: XCTestCase {

    // MARK: - Finding the public half

    /// A profile stores the *private* key path — that's what `ssh -i` wants.
    /// Pushing that would be a catastrophe, so the `.pub` beside it is what
    /// gets resolved.
    func testResolvesThePublicKeyBesideTheIdentityFile() {
        var profile = CredentialProfile(name: "ops")
        profile.identityFile = "/keys/id_ed25519"
        let path = CredentialProfileKey.publicKeyPath(
            for: profile, fileExists: { $0 == "/keys/id_ed25519.pub" })
        XCTAssertEqual(path, "/keys/id_ed25519.pub")
    }

    /// People do point a profile at the `.pub` by mistake; don't produce
    /// `id_ed25519.pub.pub`.
    func testAProfileAlreadyNamingThePubIsNotDoubleSuffixed() {
        var profile = CredentialProfile(name: "ops")
        profile.identityFile = "/keys/id_ed25519.pub"
        let path = CredentialProfileKey.publicKeyPath(
            for: profile, fileExists: { $0 == "/keys/id_ed25519.pub" })
        XCTAssertEqual(path, "/keys/id_ed25519.pub")
    }

    func testTildeIsExpanded() {
        var profile = CredentialProfile(name: "ops")
        profile.identityFile = "~/.ssh/id_ed25519"
        let expected = (("~/.ssh/id_ed25519.pub") as NSString).expandingTildeInPath
        XCTAssertEqual(CredentialProfileKey.publicKeyPath(for: profile, fileExists: { $0 == expected }),
                       expected)
    }

    /// A profile pointing at a key with no public half is a real situation
    /// (agent-only setups). Offer nothing rather than guess at a path.
    func testNoPublicHalfMeansNoOffer() {
        var profile = CredentialProfile(name: "ops")
        profile.identityFile = "/keys/id_ed25519"
        XCTAssertNil(CredentialProfileKey.publicKeyPath(for: profile, fileExists: { _ in false }))
    }

    func testProfileWithNoIdentityFileOffersNothing() {
        var profile = CredentialProfile(name: "password only")
        XCTAssertNil(CredentialProfileKey.publicKeyPath(for: profile, fileExists: { _ in true }))
        profile.identityFile = "   "
        XCTAssertNil(CredentialProfileKey.publicKeyPath(for: profile, fileExists: { _ in true }))
    }

    // MARK: - Which hosts a profile covers

    private func host(_ name: String, profile: UUID? = nil, alias: String? = nil,
                      kind: SessionKind = .host) -> SessionEntry {
        var e = SessionEntry(name: name)
        e.kind = kind
        e.hostname = "\(name).internal"
        e.credentialProfileID = profile
        e.sshAlias = alias
        return e
    }

    func testExplicitlyAssignedHostsAreIncluded() {
        let profile = CredentialProfile(name: "ops")
        let entries = [host("a", profile: profile.id), host("b"), host("c", profile: profile.id)]
        let hosts = CredentialProfileKey.hosts(using: profile, in: entries, defaultProfileID: nil)
        XCTAssertEqual(hosts.map(\.name), ["a", "c"])
    }

    /// The default profile also covers every host that has none of its own —
    /// which can be most of the library, and is why the count is surfaced
    /// before the sheet opens.
    func testTheDefaultProfileAlsoCoversUnassignedHosts() {
        let profile = CredentialProfile(name: "default")
        let other = UUID()
        let entries = [host("a", profile: profile.id), host("b"), host("c", profile: other)]
        let hosts = CredentialProfileKey.hosts(using: profile, in: entries,
                                               defaultProfileID: profile.id)
        XCTAssertEqual(hosts.map(\.name), ["a", "b"])
    }

    /// Not the default: an unassigned host is nothing to do with this profile.
    func testANonDefaultProfileDoesNotClaimUnassignedHosts() {
        let profile = CredentialProfile(name: "ops")
        let entries = [host("a", profile: profile.id), host("b")]
        let hosts = CredentialProfileKey.hosts(using: profile, in: entries,
                                               defaultProfileID: UUID())
        XCTAssertEqual(hosts.map(\.name), ["a"])
    }

    /// `~/.ssh/config` owns an aliased host's identity file, so the profile's
    /// key may not be the one it presents. Installing on that basis would be
    /// acting on a guess.
    func testAliasedHostsAreExcluded() {
        let profile = CredentialProfile(name: "ops")
        let entries = [host("a", profile: profile.id),
                       host("b", profile: profile.id, alias: "b-prod")]
        let hosts = CredentialProfileKey.hosts(using: profile, in: entries, defaultProfileID: nil)
        XCTAssertEqual(hosts.map(\.name), ["a"])
    }

    /// Serial and telnet have no `authorized_keys`, even when someone has
    /// assigned them a profile.
    func testNonSSHKindsAreExcluded() {
        let profile = CredentialProfile(name: "ops")
        let entries = [host("a", profile: profile.id),
                       host("console", profile: profile.id, kind: .serial),
                       host("sw", profile: profile.id, kind: .telnet)]
        let hosts = CredentialProfileKey.hosts(using: profile, in: entries, defaultProfileID: nil)
        XCTAssertEqual(hosts.map(\.name), ["a"])
    }

    func testActionTitleSingularises() {
        XCTAssertEqual(CredentialProfileKey.actionTitle(hostCount: 1),
                       "Copy Key to 1 Host Using This Profile…")
        XCTAssertEqual(CredentialProfileKey.actionTitle(hostCount: 12),
                       "Copy Key to 12 Hosts Using This Profile…")
    }
}
