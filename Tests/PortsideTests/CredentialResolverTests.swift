import Foundation
import XCTest
@testable import Portside

/// Precedence is tested through the pure `source` describer rather than the
/// live resolver: `CredentialStore` wraps the real system Keychain with no test
/// seam, and exercising it from a test run has destroyed a real credential
/// before. The ordering is the part that was wrong, and it's fully expressible
/// without touching a secret.
final class CredentialResolverTests: XCTestCase {

    func testAssignedProfileWinsOverEverything() {
        XCTAssertEqual(
            CredentialResolver.source(savePassword: true, hasAssignedProfilePassword: true,
                                      hasHostPassword: true, hasDefaultProfilePassword: true,
                                      hasLegacyDefault: true),
            .assignedProfile
        )
    }

    func testHostPasswordWinsWhenNoProfileIsAssigned() {
        XCTAssertEqual(
            CredentialResolver.source(savePassword: true, hasAssignedProfilePassword: false,
                                      hasHostPassword: true, hasDefaultProfilePassword: true,
                                      hasLegacyDefault: true),
            .hostSpecific
        )
    }

    /// The tunnel bug: a host with no password of its own, relying on the
    /// default profile, resolved to nothing and failed to authenticate.
    func testDefaultProfileCoversAHostWithNoPasswordOfItsOwn() {
        XCTAssertEqual(
            CredentialResolver.source(savePassword: true, hasAssignedProfilePassword: false,
                                      hasHostPassword: false, hasDefaultProfilePassword: true,
                                      hasLegacyDefault: false),
            .defaultProfile
        )
    }

    func testLegacyDefaultIsTheLastResort() {
        XCTAssertEqual(
            CredentialResolver.source(savePassword: true, hasAssignedProfilePassword: false,
                                      hasHostPassword: false, hasDefaultProfilePassword: false,
                                      hasLegacyDefault: true),
            .legacyDefault
        )
    }

    /// `savePassword` covers the host's *own* credentials only. A profile is
    /// consented to by being assigned (or nominated as the default), so it
    /// applies to a host that never ticked the box — the state every freshly
    /// imported host is in, and the reason a correctly configured default
    /// profile used to authenticate nothing at all.
    func testAssignedProfileAppliesWithoutThePerHostToggle() {
        XCTAssertEqual(
            CredentialResolver.source(savePassword: false, hasAssignedProfilePassword: true,
                                      hasHostPassword: true, hasDefaultProfilePassword: true,
                                      hasLegacyDefault: true),
            .assignedProfile
        )
    }

    func testDefaultProfileAppliesWithoutThePerHostToggle() {
        XCTAssertEqual(
            CredentialResolver.source(savePassword: false, hasAssignedProfilePassword: false,
                                      hasHostPassword: false, hasDefaultProfilePassword: true,
                                      hasLegacyDefault: false),
            .defaultProfile
        )
    }

    func testOptingOutStillSuppressesTheHostsOwnCredentials() {
        // The toggle is consent for what's stored against the host itself:
        // its own Keychain entry and the legacy app-wide default.
        XCTAssertEqual(
            CredentialResolver.source(savePassword: false, hasAssignedProfilePassword: false,
                                      hasHostPassword: true, hasDefaultProfilePassword: false,
                                      hasLegacyDefault: true),
            .none
        )
    }

    func testNothingStoredResolvesToNothing() {
        XCTAssertEqual(
            CredentialResolver.source(savePassword: true, hasAssignedProfilePassword: false,
                                      hasHostPassword: false, hasDefaultProfilePassword: false,
                                      hasLegacyDefault: false),
            .none
        )
    }

    /// No profile assigned, none nominated as default, toggle off: there is
    /// nothing this host could authenticate with, and no Keychain lookup that
    /// could change that.
    func testAHostWithNoProfileAndNoToggleResolvesToNil() {
        var entry = SessionEntry(name: "web")
        entry.savePassword = false
        entry.credentialProfileID = nil
        XCTAssertNil(CredentialResolver.password(for: entry, defaultProfileID: nil))
    }
}
