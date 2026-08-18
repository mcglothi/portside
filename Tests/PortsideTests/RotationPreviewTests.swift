import XCTest
@testable import Portside

/// The preview seeds fabricated results so the sheet's later stages can be
/// looked at. A seeded `verified` is the exact record that authorises removing
/// a key from a live host, so what this must never do is arm anything.
final class RotationPreviewTests: XCTestCase {

    func testTheRecognisedStages() {
        XCTAssertEqual(RotationPreview.plan(from: "add"),
                       .init(stage: .add, confirming: false))
        XCTAssertEqual(RotationPreview.plan(from: "verify"),
                       .init(stage: .verify, confirming: false))
        XCTAssertEqual(RotationPreview.plan(from: "retire"),
                       .init(stage: .retire, confirming: false))
        XCTAssertEqual(RotationPreview.plan(from: "confirm-retire"),
                       .init(stage: .retire, confirming: true))
    }

    /// A typo must do nothing rather than open something unexpected.
    func testAnythingElseIsIgnored() {
        for value in ["", "  ", "retyre", "RETIRE ALL", "true", "1"] {
            XCTAssertNil(RotationPreview.plan(from: value), "accepted \(value)")
        }
        XCTAssertNil(RotationPreview.plan(from: nil))
    }

    func testCaseAndWhitespaceAreTolerated() {
        XCTAssertEqual(RotationPreview.plan(from: "  Retire "),
                       .init(stage: .retire, confirming: false))
    }

    /// Not "everything succeeded" — the states worth looking at are the awkward
    /// ones, and a screenshot of five green ticks proves nothing about the
    /// layout that matters.
    func testTheSeedProducesAMixtureIncludingFailures() {
        var r = KeyRotation(hosts: (0..<6).map { i in
            var e = SessionEntry(name: "h\(i)"); e.kind = .host; e.hostname = "h\(i).internal"
            return e
        }, newKey: previewKey, oldKey: previewOldKey)
        RotationPreview.seed(&r)

        XCTAssertGreaterThan(r.verifiedCount, 0, "nothing verified — stage three would be empty")
        XCTAssertGreaterThan(r.retiredCount, 0, "no completed retirement to look at")
        XCTAssertFalse(r.awaitingRetirement.isEmpty, "nothing left for the retire button to act on")
        // A host that verified but must NOT be retired from, and one that never
        // got the key at all — the two exclusions the confirmation has to show.
        XCTAssertLessThan(r.retirable.count, r.hosts.count,
                          "every host retirable means the gate is invisible in the preview")
    }

    /// The banner has to name the variable, or a screenshot of fabricated
    /// results is indistinguishable from a real run.
    func testTheBannerNamesTheEnvironmentVariable() {
        XCTAssertTrue(RotationPreview.banner.contains(RotationPreview.environmentKey))
        XCTAssertTrue(RotationPreview.banner.lowercased().contains("disabled"))
    }

    private let previewKey = PublicKey(
        path: "/n.pub", line: "ssh-ed25519 AAAANEW t@n", algorithm: "ssh-ed25519",
        blob: "AAAANEW", comment: "t@n", fingerprint: "SHA256:n", bits: 256)
    private let previewOldKey = PublicKey(
        path: "/o.pub", line: "ssh-rsa AAAAOLD t@o", algorithm: "ssh-rsa",
        blob: "AAAAOLD", comment: "t@o", fingerprint: "SHA256:o", bits: 4096)
}
