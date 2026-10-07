import XCTest
@testable import Portside

final class ConnectionLinkTests: XCTestCase {
    private func parse(_ s: String) throws -> ConnectionLink {
        try ConnectionLink.parse(URL(string: s)!)
    }

    func testSSHForms() throws {
        XCTAssertEqual(try parse("ssh://web01"), .ssh(user: nil, host: "web01", port: nil))
        XCTAssertEqual(try parse("ssh://deploy@web01.example.com:2222"),
                       .ssh(user: "deploy", host: "web01.example.com", port: 2222))
        XCTAssertEqual(try parse("ssh://root@[fe80::1]:22"), .ssh(user: "root", host: "fe80::1", port: 22))
    }

    func testPortsideConnect() throws {
        XCTAssertEqual(try parse("portside://connect/web%2001"), .named("web 01"))
        XCTAssertThrowsError(try parse("portside://connect/"))
        XCTAssertThrowsError(try parse("portside://delete/web01"))
    }

    /// The whole point of strict parsing: nothing may reach ssh as an option.
    func testOptionInjectionIsRefused() {
        XCTAssertThrowsError(try parse("ssh://-oProxyCommand=open%20-a%20Calculator"))
        XCTAssertThrowsError(try parse("ssh://-oProxyCommand=x@host"))
        XCTAssertThrowsError(try parse("ssh://host%20-oProxyCommand=x"))
        XCTAssertThrowsError(try parse("ssh://a%3Bb@host"))
        XCTAssertThrowsError(try parse("ssh://"))
        XCTAssertThrowsError(try parse("http://web01"))
    }

    /// Refused hosts are validated encoded but shown decoded, minus anything
    /// that could break up the alert.
    func testRefusedHostIsShownReadably() {
        XCTAssertThrowsError(try parse("ssh://my%20host")) { error in
            XCTAssertEqual(error as? ConnectionLink.ParseError,
                           .invalid("The link's host \u{201C}my host\u{201D} isn't a valid host name or address."))
        }
        XCTAssertThrowsError(try parse("ssh://evil%0A%0Ahost%20x")) { error in
            XCTAssertFalse(error.localizedDescription.contains("\n"))
            XCTAssertTrue(error.localizedDescription.contains("evilhost x"))
        }
    }

    func testMatchingRespectsUserAndPort() throws {
        var saved = SessionEntry(name: "web", folder: "", hostname: "web01.example.com")
        saved.user = "deploy"
        let other = SessionEntry(name: "db", folder: "", hostname: "db01")
        let library = [other, saved]

        XCTAssertEqual(try parse("ssh://web01.example.com").match(in: library)?.id, saved.id)
        XCTAssertEqual(try parse("ssh://deploy@web01.example.com:22").match(in: library)?.id, saved.id)
        XCTAssertNil(try parse("ssh://root@web01.example.com").match(in: library),
                     "a different user must not silently open the saved login")
        XCTAssertNil(try parse("ssh://web01.example.com:2222").match(in: library))
        XCTAssertEqual(try parse("portside://connect/WEB").match(in: library)?.id, saved.id)
    }

    func testAdHocEntryOnlyForSSH() throws {
        let entry = try parse("ssh://ops@new-box:2200").adHocEntry
        XCTAssertEqual(entry?.hostname, "new-box")
        XCTAssertEqual(entry?.user, "ops")
        XCTAssertEqual(entry?.port, 2200)
        XCTAssertNil(try parse("portside://connect/x").adHocEntry)
    }
}
