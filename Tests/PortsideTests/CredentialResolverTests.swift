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

    func testOptingOutOfSavedPasswordsBeatsEveryStoredCredential() {
        // The toggle is consent, not a hint: a stored password must not be
        // used by a host that has saving switched off.
        XCTAssertEqual(
            CredentialResolver.source(savePassword: false, hasAssignedProfilePassword: true,
                                      hasHostPassword: true, hasDefaultProfilePassword: true,
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

    func testAHostThatNeverOptedInResolvesToNilWithoutTouchingTheKeychain() {
        // savePassword == false short-circuits before any CredentialStore call.
        var entry = SessionEntry(name: "web")
        entry.savePassword = false
        XCTAssertNil(CredentialResolver.password(for: entry, defaultProfileID: UUID()))
    }
}
