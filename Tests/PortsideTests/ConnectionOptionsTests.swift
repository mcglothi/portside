import XCTest
@testable import Portside

final class ConnectionOptionsTests: XCTestCase {
    private func host() -> SessionEntry {
        SessionEntry(name: "box", folder: "", hostname: "box.example.com")
    }

    func testUnsetOptionsPassNothing() {
        XCTAssertEqual(host().sshOptionArgs, [], "unset switches must leave ~/.ssh/config in charge")
    }

    func testExplicitOnAndOff() {
        var e = host()
        e.forwardAgent = true
        e.forwardX11 = false
        XCTAssertEqual(e.sshOptionArgs, ["-A", "-x"])
        e.forwardAgent = false
        e.forwardX11 = true
        XCTAssertEqual(e.sshOptionArgs, ["-a", "-Y"], "On means trusted")
        e.forwardX11Untrusted = true
        XCTAssertEqual(e.sshOptionArgs, ["-a", "-X"])
        e.forwardX11 = false
        XCTAssertEqual(e.sshOptionArgs, ["-a", "-x"], "off ignores the trust setting")
    }

    /// The editor's one picker over the two fields, both ways round.
    func testX11ModeRoundTrips() {
        var e = host()
        for mode in SessionEntry.X11Mode.allCases {
            e.x11Mode = mode
            XCTAssertEqual(e.x11Mode, mode)
        }
        e.x11Mode = .untrusted
        XCTAssertEqual(e.forwardX11, true)
        XCTAssertTrue(e.forwardX11Untrusted)
        e.x11Mode = .trusted
        XCTAssertFalse(e.forwardX11Untrusted)
        e.x11Mode = .sshConfig
        XCTAssertNil(e.forwardX11)
    }

    /// Gate 5: a host saved with X11 "On" before trust existed is trusted
    /// now — the change the release notes announce — and one saved untrusted
    /// stays untrusted across a save.
    func testX11OnFromBeforeTrustExistedIsTrusted() throws {
        let old = #"{"id":"5E0C4C1E-9B3A-4F7E-9E2B-1A2B3C4D5E6F","name":"ora08","hostname":"shd-dv-ora08","forwardX11":true}"#
        let e = try JSONDecoder().decode(SessionEntry.self, from: Data(old.utf8))
        XCTAssertEqual(e.x11Mode, .trusted)
        XCTAssertEqual(e.sshOptionArgs.first, "-Y")

        var untrusted = e
        untrusted.x11Mode = .untrusted
        let back = try JSONDecoder().decode(SessionEntry.self, from: JSONEncoder().encode(untrusted))
        XCTAssertEqual(back.x11Mode, .untrusted)
    }

    func testKeepAlive() {
        var e = host()
        e.keepAliveSeconds = 30
        XCTAssertEqual(e.keepAliveArgs,
                       ["-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3"])
        e.keepAliveSeconds = 0
        XCTAssertEqual(e.keepAliveArgs, [])
    }

    /// Options must precede the destination, or ssh reads them as the remote command.
    func testInvocationPutsOptionsBeforeDestination() {
        var e = host()
        e.forwardAgent = true
        let args = SSHInvocation.arguments(for: e, autoAcceptNewHostKeys: false)
        XCTAssertEqual(args.last, "box.example.com")
        XCTAssertTrue(args.contains("-A"))
        XCTAssertEqual(SSHInvocation.explainArguments(for: e, autoAcceptNewHostKeys: false).first, "-G")
    }

    func testRoundTripAndOldLibrariesStillLoad() throws {
        var e = host()
        e.forwardX11 = true
        e.keepAliveSeconds = 15
        let decoded = try JSONDecoder().decode(SessionEntry.self, from: JSONEncoder().encode(e))
        XCTAssertEqual(decoded.forwardX11, true)
        XCTAssertNil(decoded.forwardAgent)
        XCTAssertEqual(decoded.keepAliveSeconds, 15)

        let old = #"{"name":"legacy","hostname":"h"}"#.data(using: .utf8)!
        let legacy = try JSONDecoder().decode(SessionEntry.self, from: old)
        XCTAssertEqual(legacy.sshOptionArgs, [])
    }

    /// X11 is personal: on a shared host the choice lives in the user's
    /// overlay, trust included, and never reaches what's published.
    func testUntrustedX11OnASharedHostIsPersonal() throws {
        let shared = host()
        var overlay = SharedOverlay(entryID: shared.id)
        overlay.forwardX11 = true
        overlay.forwardX11Untrusted = true
        let reloaded = try JSONDecoder().decode(SharedOverlay.self, from: JSONEncoder().encode(overlay))
        XCTAssertEqual(reloaded.applied(to: shared).x11Mode, .untrusted)

        var mine = shared
        mine.x11Mode = .untrusted
        let published = SharedManifest.sanitized(mine, sourceID: UUID())
        XCTAssertEqual(published?.x11Mode, SessionEntry.X11Mode.sshConfig, "X11 settings aren't published")
        XCTAssertEqual(published?.forwardX11Untrusted, false)
    }
}
