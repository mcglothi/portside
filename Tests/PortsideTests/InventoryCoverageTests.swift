import Foundation
import XCTest
@testable import Portside

final class InventoryCoverageTests: XCTestCase {

    private func host(_ name: String) -> SessionEntry {
        SessionEntry(name: name, hostname: "\(name).example.com")
    }

    private let noDefaults = ConnectionDefaults()

    // MARK: - Environment

    func testUntaggedHostsAreReportedAndTaggedOnesAreNot() {
        var tagged = host("a")
        tagged.environment = .prod
        let untagged = host("b")

        let findings = InventoryCoverage.findings(
            entries: [tagged, untagged], defaults: noDefaults, profiles: []
        )
        let gap = findings.first { $0.gap == .noEnvironment }
        XCTAssertEqual(gap?.entries.map(\.name), ["b"])
    }

    // MARK: - Credential profile

    func testHostWithoutAProfileIsReported() {
        let findings = InventoryCoverage.findings(
            entries: [host("a")], defaults: noDefaults, profiles: []
        )
        XCTAssertEqual(findings.first { $0.gap == .noCredentialProfile }?.entries.count, 1)
    }

    func testDanglingProfileReferenceCountsAsMissing() {
        // The host looks configured but points at a deleted profile, so a
        // rotation would silently miss it — worse than being obviously unset.
        var orphan = host("a")
        orphan.credentialProfileID = UUID()

        let findings = InventoryCoverage.findings(
            entries: [orphan], defaults: noDefaults, profiles: []
        )
        XCTAssertEqual(findings.first { $0.gap == .noCredentialProfile }?.entries.map(\.name), ["a"])
    }

    func testHostWithALiveProfileIsNotReported() {
        let profile = CredentialProfile(name: "Standard AD")
        var assigned = host("a")
        assigned.credentialProfileID = profile.id

        let findings = InventoryCoverage.findings(
            entries: [assigned], defaults: noDefaults, profiles: [profile]
        )
        XCTAssertNil(findings.first { $0.gap == .noCredentialProfile })
    }

    // MARK: - Stored credentials

    func testHostWithItsOwnKeyIsNotReportedAsUncredentialed() {
        var keyed = host("a")
        keyed.identityFile = "~/.ssh/id_ed25519"

        let findings = InventoryCoverage.findings(
            entries: [keyed], defaults: noDefaults, profiles: []
        )
        XCTAssertNil(findings.first { $0.gap == .noStoredCredentials })
    }

    func testADefaultIdentityCoversHostsThatSetNothing() {
        // The app-wide default key applies at connect time, so a bare host is
        // genuinely covered by it — reporting it would be a false positive.
        var defaults = ConnectionDefaults()
        defaults.identityFile = "~/.ssh/id_ed25519"

        let findings = InventoryCoverage.findings(
            entries: [host("a")], defaults: defaults, profiles: []
        )
        XCTAssertNil(findings.first { $0.gap == .noStoredCredentials })
    }

    func testSavedPasswordCountsAsCredentials() {
        var saved = host("a")
        saved.savePassword = true

        let findings = InventoryCoverage.findings(
            entries: [saved], defaults: noDefaults, profiles: []
        )
        XCTAssertNil(findings.first { $0.gap == .noStoredCredentials })
    }

    func testProfileWithoutAKeyStillCountsAsCredentials() {
        // Its password lives in the Keychain, which must not be read just to
        // draw this list (CredentialStore has no test seam and hits the real
        // Keychain), so a profile assignment is taken at face value.
        let profile = CredentialProfile(name: "Ansible SVC")
        var assigned = host("a")
        assigned.credentialProfileID = profile.id

        let findings = InventoryCoverage.findings(
            entries: [assigned], defaults: noDefaults, profiles: [profile]
        )
        XCTAssertNil(findings.first { $0.gap == .noStoredCredentials })
    }

    // MARK: - Scope

    func testNonHostSessionsAreIgnored() {
        // A serial console or local shell has no credentials or environment to
        // speak of; counting them would be permanent noise.
        var serial = SessionEntry(name: "switch")
        serial.kind = .serial

        let findings = InventoryCoverage.findings(
            entries: [serial], defaults: noDefaults, profiles: []
        )
        XCTAssertTrue(findings.isEmpty)
    }

    func testGapsWithNoHostsAreOmittedEntirely() {
        var complete = host("a")
        complete.environment = .prod
        complete.identityFile = "~/.ssh/id_ed25519"
        let profile = CredentialProfile(name: "P")
        complete.credentialProfileID = profile.id

        let findings = InventoryCoverage.findings(
            entries: [complete], defaults: noDefaults, profiles: [profile]
        )
        XCTAssertTrue(findings.isEmpty, "a fully covered library should report nothing")
    }

    func testFindingsAreSortedByName() {
        let findings = InventoryCoverage.findings(
            entries: [host("zeta"), host("alpha"), host("Mike")],
            defaults: noDefaults, profiles: []
        )
        XCTAssertEqual(
            findings.first { $0.gap == .noEnvironment }?.entries.map(\.name),
            ["alpha", "Mike", "zeta"]
        )
    }

    // MARK: - Summary

    func testCoveredFractionIsNilWithNoHosts() {
        XCTAssertNil(InventoryCoverage.coveredFraction(
            entries: [], defaults: noDefaults, profiles: []
        ))
    }

    func testCoveredFractionCountsOnlyFullyCoveredHosts() {
        var good = host("good")
        good.environment = .prod
        good.identityFile = "~/.ssh/k"

        let bad = host("bad")

        let fraction = InventoryCoverage.coveredFraction(
            entries: [good, bad], defaults: noDefaults, profiles: []
        )
        XCTAssertEqual(fraction, 0.5)
    }

    func testAHostWithItsOwnKeyCountsAsFullyCovered() {
        // Not using a shared profile is a legitimate setup; scoring it as a gap
        // made 100% unreachable and the number meaningless.
        var solo = host("solo")
        solo.environment = .dev
        solo.identityFile = "~/.ssh/id_ed25519"

        XCTAssertEqual(
            InventoryCoverage.coveredFraction(entries: [solo], defaults: noDefaults, profiles: []),
            1.0
        )
        // Still reported, just not scored.
        let findings = InventoryCoverage.findings(entries: [solo], defaults: noDefaults, profiles: [])
        XCTAssertNotNil(findings.first { $0.gap == .noCredentialProfile })
    }
}
