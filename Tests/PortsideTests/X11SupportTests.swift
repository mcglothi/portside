import XCTest
@testable import Portside

final class X11SupportTests: XCTestCase {
    private let installed: (String) -> Bool = { $0 == "/Applications/Utilities/XQuartz.app" }

    func testStatus() {
        XCTAssertEqual(X11Support.status(environment: [:], exists: { _ in false }), .notInstalled)
        XCTAssertEqual(X11Support.status(environment: [:], exists: installed), .notRunning)
        XCTAssertEqual(X11Support.status(environment: ["DISPLAY": ""], exists: installed), .notRunning)
        XCTAssertEqual(X11Support.status(environment: ["DISPLAY": "/private/tmp/x:0"], exists: installed), .ready)
    }

    /// Only hosts that explicitly ask for X11 hear about XQuartz.
    func testNoticeOnlyForHostsThatTurnX11On() {
        var e = SessionEntry(name: "hopper", folder: "", hostname: "hopper")
        XCTAssertNil(X11Support.connectNotice(for: e, status: .notInstalled), "ssh config default")
        e.forwardX11 = false
        XCTAssertNil(X11Support.connectNotice(for: e, status: .notInstalled))
        e.forwardX11 = true
        XCTAssertNil(X11Support.connectNotice(for: e, status: .ready))
        XCTAssertNotNil(X11Support.connectNotice(for: e, status: .notInstalled))
        XCTAssertNotNil(X11Support.connectNotice(for: e, status: .notRunning))
        e.kind = .container
        XCTAssertNil(X11Support.connectNotice(for: e, status: .notInstalled))
    }

    /// A fresh XQuartz install is running before this login has DISPLAY
    /// exported. That's ready, not "log out and back in": ssh gets :0.
    func testARunningXQuartzWithoutDisplayIsReadyAndSshGetsColonZero() {
        let running: (String) -> Bool = { $0 == "/Applications/Utilities/XQuartz.app" || $0 == X11Support.displaySocket }
        XCTAssertEqual(X11Support.status(environment: [:], exists: running), .ready)
        XCTAssertEqual(X11Support.displayEnvironment(environment: [:], exists: running), "DISPLAY=:0")
        XCTAssertNil(X11Support.displayEnvironment(environment: ["DISPLAY": "/private/tmp/x:0"], exists: running),
                     "a DISPLAY Portside already has is left alone")
        XCTAssertNil(X11Support.displayEnvironment(environment: [:], exists: installed), "not running: nothing to point at")
    }


    /// The effective setting from `ssh -G`, so a ~/.ssh/config Host block
    /// that didn't match a short hostname shows up as "off".
    func testTheExplanationSaysWhatX11ResolvedTo() {
        func x11(_ g: String) -> String? {
            ConnectionExplanation.parse(sshDashG: "hostname h\nuser u\nport 22\n" + g, credentialSource: .none)
                .items.first { $0.label == "X11 forwarding" }?.value
        }
        XCTAssertEqual(x11("forwardx11 yes\nforwardx11trusted yes\n"), "on, trusted")
        XCTAssertEqual(x11("forwardx11 yes\nforwardx11trusted no\n"), "on, untrusted")
        XCTAssertEqual(x11("forwardx11 no\nforwardx11trusted no\n"), "off")
    }
}
