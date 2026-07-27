import AppKit
import Foundation
import XCTest
@testable import Portside

/// The app appearance is persisted inside `TerminalAppearance`, which every
/// existing library on disk already has — written without this key. Decoding has
/// to tolerate that, because the 0.16 audit found that a partial read of the
/// library wrote empty defaults back over real data.
final class AppAppearanceTests: XCTestCase {

    private func decode(_ json: String) throws -> TerminalAppearance {
        try JSONDecoder().decode(TerminalAppearance.self, from: Data(json.utf8))
    }

    func testDefaultsToFollowingTheSystem() {
        XCTAssertEqual(TerminalAppearance(themeName: "Portside Dark",
                                          foregroundHex: "#FFFFFF",
                                          backgroundHex: "#000000",
                                          cursorHex: "#FFFFFF",
                                          ansiHex: TerminalTheme.systemDefault.ansi).appAppearance,
                       .followSystem)
    }

    /// A library written by 0.16 or earlier.
    func testMissingKeyDecodesToFollowSystem() throws {
        let appearance = try decode(#"{"fontName":"Menlo","fontSize":13}"#)
        XCTAssertEqual(appearance.appAppearance, .followSystem)
        XCTAssertEqual(appearance.fontName, "Menlo")
    }

    /// A library written by some future build that grew a fourth option. This
    /// must not throw — throwing here fails the whole appearance decode, and the
    /// rest of the library with it.
    func testUnknownValueDecodesToFollowSystemWithoutThrowing() throws {
        let appearance = try decode(#"{"fontName":"Menlo","appAppearance":"solarizedAutoDusk"}"#)
        XCTAssertEqual(appearance.appAppearance, .followSystem)
        XCTAssertEqual(appearance.fontName, "Menlo", "the rest of the appearance must survive")
    }

    func testRoundTripsThroughEncoding() throws {
        for expected in AppAppearance.allCases {
            var appearance = TerminalAppearance(themeName: "Portside Dark",
                                                foregroundHex: "#FFFFFF",
                                                backgroundHex: "#000000",
                                                cursorHex: "#FFFFFF",
                                                ansiHex: TerminalTheme.systemDefault.ansi)
            appearance.appAppearance = expected

            let data = try JSONEncoder().encode(appearance)
            let decoded = try JSONDecoder().decode(TerminalAppearance.self, from: data)

            XCTAssertEqual(decoded.appAppearance, expected)
        }
    }

    /// "Follow system" has to be `nil`, not a concrete appearance — that is how
    /// `NSApplication` is told to hand the decision back to macOS. Returning
    /// `.aqua` here would pin the app to light and look identical until the
    /// user switched their system theme.
    func testFollowSystemMapsToNilAppearance() {
        XCTAssertNil(AppAppearance.followSystem.nsAppearance)
        XCTAssertEqual(AppAppearance.light.nsAppearance?.name, .aqua)
        XCTAssertEqual(AppAppearance.dark.nsAppearance?.name, .darkAqua)
    }

    /// The setting must stay independent of the terminal's own colours: a dark
    /// terminal inside a light app is a normal preference, and coupling them
    /// was explicitly ruled out during planning.
    func testChangingAppAppearanceLeavesTerminalColoursAlone() {
        var appearance = TerminalAppearance(themeName: "Portside Dark",
                                            foregroundHex: "#FFFFFF",
                                            backgroundHex: "#000000",
                                            cursorHex: "#FFFFFF",
                                            ansiHex: TerminalTheme.systemDefault.ansi)
        let before = appearance

        appearance.appAppearance = .light

        XCTAssertEqual(appearance.foregroundHex, before.foregroundHex)
        XCTAssertEqual(appearance.backgroundHex, before.backgroundHex)
        XCTAssertEqual(appearance.cursorHex, before.cursorHex)
        XCTAssertEqual(appearance.themeName, before.themeName)
        XCTAssertEqual(appearance.ansiHex, before.ansiHex)
    }
}
