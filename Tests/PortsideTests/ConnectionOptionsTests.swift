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
        XCTAssertEqual(e.sshOptionArgs, ["-a", "-X"])
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
}
