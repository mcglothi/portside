import Foundation
import XCTest
@testable import Portside

final class TelnetTests: XCTestCase {
    func testTargetDefaultsToStandardPort() {
        XCTAssertEqual(TelnetTarget().port, 23)
    }

    func testTargetFallsBackToStandardPortForInvalidStoredValue() {
        XCTAssertEqual(TelnetTarget(host: "router", port: 0).resolvedPort, 23)
        XCTAssertEqual(TelnetTarget(host: "router", port: 70_000).resolvedPort, 23)
        XCTAssertEqual(TelnetTarget(host: "router", port: 2323).resolvedPort, 2323)
    }

    func testTelnetSubtitleAndLogKeyUseHostAndPort() {
        var entry = SessionEntry(name: "legacy-switch")
        entry.kind = .telnet
        entry.telnet = TelnetTarget(host: "switch.example.test", port: 2323)
        XCTAssertEqual(entry.subtitle, "switch.example.test:2323")
        XCTAssertEqual(LogManager.hostKey(for: entry), "switch.example.test_2323")
    }

    func testTelnetDoesNotOfferFileBrowser() {
        var entry = SessionEntry(name: "legacy-switch")
        entry.kind = .telnet
        XCTAssertFalse(entry.supportsFileBrowser)
    }

    func testTelnetTargetRoundTripsAndOldLibrariesStillLoad() throws {
        var entry = SessionEntry(name: "legacy-switch")
        entry.kind = .telnet
        entry.telnet = TelnetTarget(host: "switch.example.test", port: 2323)
        let decoded = try JSONDecoder().decode(SessionEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(decoded.telnet, entry.telnet)

        let old = #"{"name": "legacy", "hostname": "10.0.0.5"}"#
        let oldEntry = try JSONDecoder().decode(SessionEntry.self, from: Data(old.utf8))
        XCTAssertNil(oldEntry.telnet)
    }

    func testNegotiatorKeepsTextAndRefusesUnknownOptions() {
        var negotiator = TelnetNegotiator()
        let result = negotiator.consume(Data([72, 105, 255, 251, 24, 33]))
        XCTAssertEqual(result.payload, [72, 105, 33])
        XCTAssertEqual(result.replies, [255, 254, 24])
    }

    func testNegotiatorAcceptsEchoAndSuppressGoAhead() {
        var negotiator = TelnetNegotiator()
        let result = negotiator.consume(Data([255, 251, 1, 255, 253, 3]))
        XCTAssertEqual(result.replies, [255, 253, 1, 255, 251, 3])
    }

    func testNegotiatorHandlesFragmentedSubnegotiationAndEscapedIAC() {
        var negotiator = TelnetNegotiator()
        XCTAssertEqual(negotiator.consume(Data([65, 255, 250, 24, 1])).payload, [65])
        XCTAssertEqual(negotiator.consume(Data([255, 240, 66, 255])).payload, [66])
        XCTAssertEqual(negotiator.consume(Data([255, 67])).payload, [255, 67])
    }

    func testOutgoingIACEscapesLiteral255() {
        XCTAssertEqual(TelnetNegotiator.escapeOutgoing([65, 255, 66]), [65, 255, 255, 66])
    }
}
