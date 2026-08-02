import XCTest
import SwiftTerm
@testable import Portside

/// Terminal compatibility suite — character width.
///
/// Width is where a terminal quietly goes wrong: nothing crashes, the cursor
/// just ends up in the wrong column and every subsequent redraw is a little
/// further off. It shows up as a corrupted prompt after an emoji in a git
/// branch name, or a box-drawing UI that shears halfway down.
///
/// These assert on the cursor, not on the rendered glyph — advance width is
/// what the *host* and the terminal have to agree on, and disagreeing is what
/// breaks ncurses and readline.
final class TerminalUnicodeTests: XCTestCase {

    /// Columns consumed by writing `text` into a fresh terminal.
    func advanceColumns(_ text: String) -> Int {
        let t = TerminalHarness()
        t.feed(text)
        return t.cursor.x
    }

    func testASCIIIsOneColumn() {
        XCTAssertEqual(advanceColumns("abc"), 3)
    }

    func testCJKIsTwoColumns() {
        // The most common real case: a hostname or path with CJK in it. Getting
        // this wrong shifts everything after it by one column per character.
        XCTAssertEqual(advanceColumns("日"), 2)
        XCTAssertEqual(advanceColumns("日本語"), 6)
    }

    func testCombiningMarksDoNotAdvance() {
        // "e" plus a combining acute is one column, not two — readline counts
        // it as one when deciding where the cursor is.
        XCTAssertEqual(advanceColumns("e\u{0301}"), 1)
    }

    func testAccentedCharactersArePrecomposedOrCombinedToOneColumn() {
        XCTAssertEqual(advanceColumns("é"), 1)      // precomposed
        XCTAssertEqual(advanceColumns("naïve"), 5)
    }

    func testBoxDrawingIsOneColumn() {
        // These are the characters an ncurses UI is made of; two-column
        // treatment would shear every frame.
        XCTAssertEqual(advanceColumns("┌─┬─┐"), 5)
        XCTAssertEqual(advanceColumns("│ │"), 3)
    }

    func testAWideCharacterAtTheRightEdgeDoesNotSplit() {
        // A double-width glyph with one column left must wrap whole, not be
        // half-written at the end of the line.
        let t = TerminalHarness(cols: 10, rows: 4)
        t.feed(String(repeating: "a", count: 9))   // one column remains
        t.feed("日")
        XCTAssertTrue(t.line(0).hasSuffix("a"), "the wide char should not sit in the last column")
        XCTAssertTrue(t.line(1).hasPrefix("日"), "it should have wrapped whole: \(t.line(1))")
    }

    func testTextAfterAWideCharacterLandsInTheRightColumn() {
        let t = TerminalHarness()
        t.feed("日x")
        XCTAssertEqual(t.cursor.x, 3, "one wide char plus one narrow is three columns")
        XCTAssertEqual(t.line(0), "日x")
    }

    func testWideCharactersSurviveChunking() {
        // Same property as the integrity suite, applied to the width path.
        let stream = Array("日本語 mixed with ascii ✅".utf8)
        let whole = TerminalHarness()
        whole.feed(stream)
        for chunk in [1, 2, 3, 5] {
            let split = TerminalHarness()
            split.feed(stream, inChunksOf: chunk)
            XCTAssertEqual(split.screen, whole.screen, "chunk size \(chunk) changed the result")
            XCTAssertEqual(split.cursor.x, whole.cursor.x, "chunk size \(chunk) moved the cursor")
        }
    }
}

// MARK: - Emoji
//
// Width only, deliberately. A buffer-level read of *glyph content* for
// multi-scalar clusters is not trustworthy — `translateToString` returns a
// space for a VS16 heart that the view renders perfectly well, so asserting on
// the text here would report bugs that don't exist and miss one that does.
// What the buffer is authoritative about is how many columns the terminal
// believes it consumed, and that is the number the host has to agree with.
extension TerminalUnicodeTests {

    func testASingleScalarEmojiIsTwoColumns() {
        XCTAssertEqual(advanceColumns("\u{2705}"), 2)      // ✅
    }

    func testAnEmojiWithAVariationSelectorIsTwoColumns() {
        XCTAssertEqual(advanceColumns("\u{2764}\u{FE0F}"), 2)   // ❤️
        XCTAssertEqual(advanceColumns("\u{2764}"), 1,
                       "without VS16 it is a text-presentation heart, one column")
    }

    func testASkinToneModifierDoesNotAddAColumn() {
        XCTAssertEqual(advanceColumns("\u{1F44D}\u{1F3FD}"), 2)  // 👍🏽
    }

    func testARegionalIndicatorPairIsOneFlagOfTwoColumns() {
        XCTAssertEqual(advanceColumns("\u{1F1EC}\u{1F1E7}"), 2)  // 🇬🇧
    }

    /// Known limitation, pinned so a SwiftTerm bump that fixes it is noticed.
    ///
    /// The buffer accounts a ZWJ sequence as a single two-column cluster, which
    /// is right. The *view* draws it as its separate components with the joiner
    /// shown literally as `<200d>` — verified in the running app, where
    /// `👨‍👩‍👧` came out as three emoji and two visible placeholders.
    ///
    /// So this is not cosmetic: the terminal's column accounting and what it
    /// paints disagree, and everything after a ZWJ emoji on that line sits in
    /// the wrong place. A prompt carrying one — which is not exotic — corrupts.
    ///
    /// The assertion is on the accounting, because that is the half this suite
    /// can see. If it ever stops being 2, the rendering contract has changed
    /// and the app is worth re-checking by eye.
    func testAZWJSequenceIsAccountedAsOneClusterEvenThoughItDrawsWrong() {
        XCTAssertEqual(advanceColumns("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"), 2,
                       "buffer accounting changed — recheck ZWJ rendering in the app")
    }
}
