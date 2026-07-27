import Foundation
import XCTest
@testable import Portside

final class MacroFavoriteTests: XCTestCase {

    private func decode(_ json: String) throws -> Macro {
        try JSONDecoder().decode(Macro.self, from: Data(json.utf8))
    }

    // MARK: - Decoding old libraries

    /// The reason `Macro` carries a hand-written decoder.
    ///
    /// Swift's *synthesized* `Decodable` ignores property defaults and throws
    /// `keyNotFound`, and `SessionStore.Document.macros` is non-optional — so a
    /// macro saved before this field existed would fail the whole library load,
    /// not just itself. Same shape as the 0.16 audit's migration P0.
    func testMacroWithoutTheNewFieldStillDecodes() throws {
        let macro = try decode(#"""
        {"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301",
         "name":"restart nginx","text":"systemctl restart nginx","sendReturn":true}
        """#)

        XCTAssertEqual(macro.name, "restart nginx")
        XCTAssertFalse(macro.isFavorite, "an existing macro is not silently pinned")
    }

    /// Older still: written before `sendReturn` existed. This was already
    /// undecodable before this change; the hand-written decoder fixes it too.
    func testMacroFromBeforeSendReturnStillDecodes() throws {
        let macro = try decode(#"{"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","name":"uptime","text":"uptime"}"#)

        XCTAssertEqual(macro.text, "uptime")
        XCTAssertTrue(macro.sendReturn, "defaults to pressing Return, as the property says")
        XCTAssertFalse(macro.isFavorite)
    }

    func testRoundTripsThroughEncoding() throws {
        var macro = Macro(name: "deploy", text: "./deploy.sh")
        macro.isFavorite = true

        let decoded = try JSONDecoder().decode(Macro.self, from: JSONEncoder().encode(macro))

        XCTAssertTrue(decoded.isFavorite)
        XCTAssertEqual(decoded.id, macro.id)
        XCTAssertEqual(decoded.text, "./deploy.sh")
    }

    // MARK: - What the bar shows

    /// Mirrors `TabContentView.barMacros`. Pinning nothing must not empty the
    /// bar for people who never favourite anything — and leaving it full is
    /// what makes the feature discoverable in the first place.
    private func barMacros(_ macros: [Macro]) -> [Macro] {
        let favorites = macros.filter(\.isFavorite)
        return favorites.isEmpty ? macros : favorites
    }

    func testBarFallsBackToEveryMacroWhenNothingIsPinned() {
        let macros = [Macro(name: "a", text: "a"), Macro(name: "b", text: "b")]
        XCTAssertEqual(barMacros(macros).map(\.name), ["a", "b"])
    }

    func testBarShowsOnlyPinnedMacrosOnceThereAreSome() {
        var pinned = Macro(name: "restart", text: "r")
        pinned.isFavorite = true
        let macros = [Macro(name: "a", text: "a"), pinned, Macro(name: "b", text: "b")]

        XCTAssertEqual(barMacros(macros).map(\.name), ["restart"])
    }

    /// Library order, not favourite-toggle order: the bar should not reshuffle
    /// itself as things are pinned.
    func testPinnedMacrosKeepLibraryOrder() {
        var first = Macro(name: "first", text: "1")
        var third = Macro(name: "third", text: "3")
        first.isFavorite = true
        third.isFavorite = true
        let macros = [first, Macro(name: "second", text: "2"), third]

        XCTAssertEqual(barMacros(macros).map(\.name), ["first", "third"])
    }
}
