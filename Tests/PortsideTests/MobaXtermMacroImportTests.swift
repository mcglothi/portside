import Foundation
import XCTest
@testable import Portside

/// MobaXterm records each keystroke as `258:<code>:<locale>:<label>`, where the
/// label is the character for printable keys and a *name* for the rest.
///
/// The importer appended the label whatever it was, so `yum update -y` imported
/// as `yumSPACEupdateSPACE-y`. Only macros containing a space (or another named
/// key) were affected, which is why it looked arbitrary. Reported from a real
/// import by Tim, 2026-07-27.
final class MobaXtermMacroImportTests: XCTestCase {

    /// Builds the `[Macros]` body for a line of printable characters, the way
    /// MobaXterm writes it: one tuple per keystroke.
    private func tuples(_ characters: [String]) -> String {
        characters.map { "258:0:0:\($0)" }.joined(separator: "|")
    }

    private func macro(named name: String, sequence: String) -> Macro? {
        MobaXtermImporter.parseMacros("[Macros]\n\(name)=\(sequence)").macros.first
    }

    // MARK: - The reported bug

    func testSpaceTokensBecomeActualSpaces() throws {
        let keys = ["y", "u", "m", "SPACE", "u", "p", "d", "a", "t", "e", "SPACE", "-", "y"]
        let imported = try XCTUnwrap(macro(named: "yum update", sequence: tuples(keys)))

        XCTAssertEqual(imported.text, "yum update -y")
    }

    /// The half of the report that explains why it looked random: a macro with
    /// no named keys imported correctly all along.
    func testMacroWithoutNamedKeysWasNeverAffected() throws {
        let imported = try XCTUnwrap(macro(named: "uptime", sequence: tuples(["u", "p", "t", "i", "m", "e"])))

        XCTAssertEqual(imported.text, "uptime")
    }

    func testTabTokenBecomesATab() throws {
        let imported = try XCTUnwrap(macro(named: "complete", sequence: tuples(["c", "d", "SPACE", "TAB"])))

        XCTAssertEqual(imported.text, "cd \t")
    }

    /// A macro that types the literal word SPACE arrives as five separate
    /// single-character tokens, so it is not confusable with the named key.
    func testTypingTheWordSpaceStillWorks() throws {
        let imported = try XCTUnwrap(macro(named: "echo", sequence: tuples(["S", "P", "A", "C", "E"])))

        XCTAssertEqual(imported.text, "SPACE")
    }

    // MARK: - Keys with no text form

    /// Dropped rather than appended. A missing keystroke is recoverable by eye;
    /// a word spliced into the middle of a command is not — which is exactly
    /// what the bug did.
    func testUnknownNamedKeysAreDroppedNotInlined() throws {
        let keys = ["l", "s", "SPACE", "UP", "F5", "HOME", "-", "l"]
        let imported = try XCTUnwrap(macro(named: "history", sequence: tuples(keys)))

        XCTAssertEqual(imported.text, "ls -l")
        XCTAssertFalse(imported.text.contains("UP"))
        XCTAssertFalse(imported.text.contains("F5"))
        XCTAssertFalse(imported.text.contains("HOME"))
    }

    // MARK: - Existing behaviour that must not regress

    func testTrailingReturnSetsSendReturnAndIsStripped() throws {
        let imported = try XCTUnwrap(
            macro(named: "restart", sequence: tuples(["p", "s"]) + "|RETURN")
        )

        XCTAssertEqual(imported.text, "ps")
        XCTAssertTrue(imported.sendReturn)
    }

    /// A RETURN in the *middle* is a real newline, and the macro does not end
    /// on one, so it should not also press Return afterwards.
    func testEmbeddedReturnIsKeptAsANewline() throws {
        let sequence = tuples(["a"]) + "|RETURN|" + tuples(["b"])
        let imported = try XCTUnwrap(macro(named: "two lines", sequence: sequence))

        XCTAssertEqual(imported.text, "a\nb")
        XCTAssertFalse(imported.sendReturn)
    }

    func testSleepTokensAreIgnored() throws {
        let sequence = tuples(["h", "i"]) + "|258:0:0:SLEEPEQUAL500"
        let imported = try XCTUnwrap(macro(named: "sleepy", sequence: sequence))

        XCTAssertEqual(imported.text, "hi")
    }

    func testImportedMacrosAreNotPinnedByDefault() throws {
        let imported = try XCTUnwrap(macro(named: "uptime", sequence: tuples(["u", "p"])))

        XCTAssertFalse(imported.isFavorite)
    }
}

/// MobaXterm escapes the characters that collide with its own file format.
/// Found by reading a real 867-host library from Tim's work machine, where
/// these were far more common than the `SPACE` that started the hunt:
/// 58 double quotes, 22 semicolons, 20 pipes, 14 equals, 11 colons.
final class MobaXtermEscapeTests: XCTestCase {

    private func tuples(_ characters: [String]) -> String {
        characters.map { "258:0:0:\($0)" }.joined(separator: "|")
    }

    private func macro(named name: String, sequence: String) -> Macro? {
        MobaXtermImporter.parseMacros("[Macros]\n\(name)=\(sequence)").macros.first
    }

    func testFormatEscapesDecodeToTheirCharacters() {
        XCTAssertEqual(MobaXtermImporter.decodeEscapes("__DBLQUO__"), "\"")
        XCTAssertEqual(MobaXtermImporter.decodeEscapes("__PTVIRG__"), ";")
        XCTAssertEqual(MobaXtermImporter.decodeEscapes("__PIIPE__"), "|")
        XCTAssertEqual(MobaXtermImporter.decodeEscapes("__EQQUAL__"), "=")
        XCTAssertEqual(MobaXtermImporter.decodeEscapes("__DBLDOT__"), ":")
    }

    /// Straight from the work library, which had it as
    /// `package-cleanup --oldkernels --count__EQQUAL__2 __PIIPE____PIIPE__ …`
    func testRealWorldPipeAndEqualsMacro() throws {
        let keys = ["c", "o", "u", "n", "t", "__EQQUAL__", "2", "SPACE",
                    "__PIIPE__", "__PIIPE__", "SPACE", "y", "u", "m"]
        let imported = try XCTUnwrap(macro(named: "kernels", sequence: tuples(keys)))

        XCTAssertEqual(imported.text, "count=2 || yum")
    }

    /// An escape stands for one character, so it has to be decoded before the
    /// label is measured — `__DBLQUO__` is eleven characters long and would
    /// otherwise be discarded as an unknown key name.
    func testEscapesSurviveTheSingleCharacterCheck() throws {
        let keys = ["e", "c", "h", "o", "SPACE", "__DBLQUO__", "h", "i", "__DBLQUO__"]
        let imported = try XCTUnwrap(macro(named: "echo", sequence: tuples(keys)))

        XCTAssertEqual(imported.text, "echo \"hi\"")
    }

    func testSemicolonAndColonEscapes() throws {
        let keys = ["a", "__PTVIRG__", "SPACE", "b", "__DBLDOT__", "c"]
        let imported = try XCTUnwrap(macro(named: "seq", sequence: tuples(keys)))

        XCTAssertEqual(imported.text, "a; b:c")
    }

    /// The macro name sits left of the `=` the format uses to split the line,
    /// so it carries escapes too.
    func testEscapesInTheMacroName() throws {
        let imported = try XCTUnwrap(
            macro(named: "disk__DBLDOT__ check", sequence: tuples(["d", "f"]))
        )

        XCTAssertEqual(imported.name, "disk: check")
    }

    func testPipeKeyLabelBecomesAPipe() throws {
        let imported = try XCTUnwrap(
            macro(named: "count", sequence: tuples(["l", "s", "SPACE", "PIPE", "SPACE", "w", "c"]))
        )

        XCTAssertEqual(imported.text, "ls | wc")
    }

    func testCtrlLabelsBecomeControlCharacters() {
        XCTAssertEqual(MobaXtermImporter.controlCharacter(for: "Ctrl+C"), "\u{03}")
        XCTAssertEqual(MobaXtermImporter.controlCharacter(for: "Ctrl+D"), "\u{04}")
        XCTAssertNil(MobaXtermImporter.controlCharacter(for: "Ctrl+"))
        XCTAssertNil(MobaXtermImporter.controlCharacter(for: "SPACE"))
    }

    func testCtrlCInAMacroSequence() throws {
        let imported = try XCTUnwrap(
            macro(named: "interrupt", sequence: tuples(["t", "o", "p", "Ctrl+C"]))
        )

        XCTAssertEqual(imported.text, "top\u{03}")
    }

    /// An unknown `__NAME__` stands for *some* literal character, so dropping it
    /// would silently change a command. Left visible so it gets reported —
    /// which is exactly how these were found.
    func testUnknownEscapesAreLeftVisibleRatherThanDropped() throws {
        let imported = try XCTUnwrap(
            macro(named: "odd", sequence: tuples(["a", "__NOPENOPE__", "b"]))
        )

        XCTAssertEqual(imported.text, "a__NOPENOPE__b")
    }
}
