import Foundation
import XCTest
@testable import Portside

final class TerminalSettingsTests: XCTestCase {

    func testDefaultScrollbackIsGenerous() {
        XCTAssertEqual(TerminalSettings().scrollbackLines, 10_000)
        XCTAssertEqual(TerminalSettings().resolvedScrollback, 10_000)
    }

    func testResolvedScrollbackClampsZeroAndNegativeUp() {
        // 0 / negative would tell SwiftTerm to *disable* scrollback; never allow it.
        var t = TerminalSettings()
        t.scrollbackLines = 0
        XCTAssertEqual(t.resolvedScrollback, 100)
        t.scrollbackLines = -5_000
        XCTAssertEqual(t.resolvedScrollback, 100)
    }

    func testResolvedScrollbackClampsAbsurdlyLargeValuesDown() {
        var t = TerminalSettings()
        t.scrollbackLines = 5_000_000
        XCTAssertEqual(t.resolvedScrollback, 100_000)
    }

    func testPresetsPassThroughUnclamped() {
        for lines in TerminalSettings.scrollbackOptions {
            var t = TerminalSettings()
            t.scrollbackLines = lines
            XCTAssertEqual(t.resolvedScrollback, lines, "preset \(lines) should not be clamped")
        }
    }

    func testMetalRendererDefaultsOff() {
        XCTAssertFalse(TerminalSettings().useMetalRenderer)
    }

    func testDecodingPartialTerminalBlockFillsMissingFieldsFromDefaults() throws {
        // A terminal block written before useMetalRenderer existed must still
        // decode, defaulting the missing field rather than throwing.
        let old = #"{"scrollbackLines": 50000}"#
        let decoded = try JSONDecoder().decode(TerminalSettings.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.scrollbackLines, 50_000)
        XCTAssertFalse(decoded.useMetalRenderer)
    }

    func testDecodingEmptyObjectUsesAllDefaults() throws {
        let decoded = try JSONDecoder().decode(TerminalSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, TerminalSettings())
    }

    func testRoundTrips() throws {
        var t = TerminalSettings()
        t.scrollbackLines = 50_000
        t.useMetalRenderer = true
        let data = try JSONEncoder().encode(t)
        let decoded = try JSONDecoder().decode(TerminalSettings.self, from: data)
        XCTAssertEqual(decoded, t)
    }

    /// `CodingKeys` is declared by hand here, so a new field that isn't added
    /// to it encodes as nothing and silently resets on every launch.
    func testInjectShellIntegrationSurvivesARoundTrip() throws {
        var t = TerminalSettings()
        t.injectShellIntegration = true
        let data = try JSONEncoder().encode(t)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("injectShellIntegration"),
                      "field is missing from CodingKeys — it would never persist")
        XCTAssertTrue(try JSONDecoder().decode(TerminalSettings.self, from: data).injectShellIntegration)
    }

    /// A library written before this field existed must still load.
    func testSettingsWrittenWithoutTheFieldStillDecode() throws {
        let json = Data(#"{"scrollbackLines":5000}"#.utf8)
        let decoded = try JSONDecoder().decode(TerminalSettings.self, from: json)
        XCTAssertEqual(decoded.scrollbackLines, 5_000)
        XCTAssertFalse(decoded.injectShellIntegration)
    }
}
