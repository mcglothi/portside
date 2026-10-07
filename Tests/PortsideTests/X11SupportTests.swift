import XCTest
@testable import Portside

final class X11SupportTests: XCTestCase {
    private let installed: (String) -> Bool = { $0 == "/Applications/Utilities/XQuartz.app" }

    func testStatus() {
        XCTAssertEqual(X11Support.status(environment: [:], exists: { _ in false }), .notInstalled)
        XCTAssertEqual(X11Support.status(environment: [:], exists: installed), .noDisplay)
        XCTAssertEqual(X11Support.status(environment: ["DISPLAY": ""], exists: installed), .noDisplay)
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
        XCTAssertNotNil(X11Support.connectNotice(for: e, status: .noDisplay))
        e.kind = .container
        XCTAssertNil(X11Support.connectNotice(for: e, status: .notInstalled))
    }
}
