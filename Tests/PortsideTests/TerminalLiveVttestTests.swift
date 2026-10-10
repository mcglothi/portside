import XCTest
import SwiftTerm

/// Terminal compatibility suite — vttest, the VT100/VT102 conformance program,
/// driven through its menus and checked screen by screen.
///
/// Each vttest screen says in words what a correct terminal shows ("an
/// unbroken border of *'s and +'s", "the right column should be staggered by
/// one"). These tests turn that sentence into an assertion on the grid, column
/// by column — `grid`, not `screen`, because vttest draws by moving the cursor
/// over untouched cells and its tests are about where things land.
///
/// Not covered, on purpose: the 132-column passes in menus 1 and 8. SwiftTerm
/// only honours DECCOLM after `CSI ? 40 h`, matching xterm's `allowC132`
/// default, and those menus don't send it; they wrap at 80 columns in xterm
/// too. Menu 2 does send it, and its 132-column screens are checked.
final class TerminalLiveVttestTests: XCTestCase {
    private func vttest() throws -> LiveTerminalHarness {
        guard let path = LiveTerminalHarness.find("vttest") else {
            throw XCTSkip("vttest isn't installed (brew install vttest)")
        }
        return LiveTerminalHarness(path, environment: ["TERM": "xterm"])
    }

    private func open(_ menu: String) async throws -> LiveTerminalHarness {
        let t = try vttest()
        await t.waitFor(text: "Enter choice number")
        t.send("\(menu)\r")
        return t
    }

    /// Presses Return and waits for a screen that satisfies `condition`.
    private func next(_ t: LiveTerminalHarness, _ what: String,
                      file: StaticString = #filePath, line: UInt = #line,
                      _ condition: @escaping ([String]) -> Bool) async {
        t.send("\r")
        await settle(t, what, file: file, line: line, condition)
    }

    /// Waits for the grid to satisfy `condition` and stop changing; on
    /// timeout, fails with the grid at full width, which is what the condition
    /// was looking at.
    ///
    /// "Stop changing" matters: vttest flushes typed-ahead input before each
    /// prompt, so a Return sent while a screen is still drawing is thrown
    /// away and every later step waits on the wrong screen.
    private func settle(_ t: LiveTerminalHarness, _ what: String,
                        file: StaticString = #filePath, line: UInt = #line,
                        _ condition: @escaping ([String]) -> Bool) async {
        let deadline = Date().addingTimeInterval(30)
        var matched: (grid: [String], since: Date)?
        while Date() < deadline {
            let grid = t.grid
            if condition(grid) {
                if let m = matched, m.grid == grid {
                    if Date().timeIntervalSince(m.since) > 0.5 { return }
                } else {
                    matched = (grid, Date())
                }
            } else {
                matched = nil
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let grid = t.grid.enumerated().map { String(format: "%2d|", $0.offset) + $0.element + "|" }
        XCTFail("timed out waiting for \(what)\n" + grid.joined(separator: "\n"), file: file, line: line)
    }

    /// Presses Return past a screen not asserted on, waiting for whatever
    /// comes next to finish drawing.
    private func skip(_ t: LiveTerminalHarness) async {
        let before = t.grid
        t.send("\r")
        var last = before
        var stableSince = Date()
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            let now = t.grid
            if now != last { last = now; stableSince = Date() }
            else if now != before, Date().timeIntervalSince(stableSince) > 0.7 { return }
        }
        XCTFail("the next screen never settled\n\(t.dump)")
    }

    private func pad(_ s: String, _ width: Int = 80) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }

    private func trim(_ row: String) -> String {
        var row = row
        while row.last == " " { row.removeLast() }
        return row
    }

    private func rightmost(_ row: String) -> Int? {
        row.lastIndex { $0 != " " }.map { row.distance(from: row.startIndex, to: $0) }
    }

    // MARK: Menu 1 — cursor movements

    func testCursorMovements() async throws {
        let t = try await open("1")
        defer { t.stop() }

        // The border and the frame of E's, cell for cell.
        let inner = [
            "",
            " The screen should be cleared,  and have an unbroken bor- ",
            " der of *'s and +'s around the edge,   and exactly in the ",
            " middle  there should be a frame of E's around this  text ",
            " with  one (1) free position around it.    Push <RETURN>  ",
            "",
        ]
        var expected = [String(repeating: "*", count: 80), "*" + String(repeating: "+", count: 78) + "*"]
        let side = { (middle: String) in "*+" + middle + "+*" }
        for row in 2...21 {
            switch row {
            case 8, 15:
                expected.append(side("        " + String(repeating: "E", count: 60) + "        "))
            case 9...14:
                expected.append(side("        E" + pad(inner[row - 9], 58) + "E        "))
            default:
                expected.append(side(String(repeating: " ", count: 76)))
            }
        }
        expected += [expected[1], expected[0]]
        await settle(t, "the border and frame") { $0 == expected }

        await skip(t)  // 132 columns: not honoured without CSI ? 40 h

        // Autowrap, twice (vttest runs it once per column mode): letters in
        // order down both margins, nothing between.
        let margins: ([String]) -> Bool = { g in
            (0..<18).allSatisfy { i in
                let row = Array(g[2 + i])
                let upper = Character(UnicodeScalar(UInt8(ascii: "I") + UInt8(i)))
                return row[0] == upper && row[79] == Character(upper.lowercased())
                    && row[1..<79].allSatisfy { $0 == " " }
            }
        }
        await next(t, "the autowrap margins, first pass", margins)
        await next(t, "the autowrap margins") { g in
            (0..<18).allSatisfy { i in
                let row = Array(g[2 + i])
                let upper = Character(UnicodeScalar(UInt8(ascii: "I") + UInt8(i)))
                return row[0] == upper && row[79] == Character(upper.lowercased())
                    && row[1..<79].allSatisfy { $0 == " " }
            } && g[22].hasPrefix("The left/right margins should have letters in order:")
        }

        await next(t, "four identical lines") { g in
            g[1].hasPrefix("Below should be four identical lines")
                && (3...6).allSatisfy { self.trim(g[$0]) == ("A B C D E F G H I") }
        }

        await next(t, "the leading-zeros sentence") { g in
            g[0].hasPrefix("Test of leading zeros") && self.trim(g[3]) == ("This is a correct sentence")
        }
    }

    // MARK: Menu 2 — screen features

    func testScreenFeatures() async throws {
        let t = try await open("2")
        defer { t.stop() }

        await settle(t, "three lines of stars") { g in
            return (0...2).allSatisfy { g[$0] == String(repeating: "*", count: 80) }
                && self.trim(g[3]) == ("") && g[4].hasPrefix("This should be three identical lines")
        }

        await next(t, "two identical tab-stop lines") { g in
            let stars = (0..<80).map { $0 % 6 == 0 && $0 > 0 ? "*" : " " }.joined()
            return g[0] == stars && g[1] == stars
        }

        // 132 then 80 columns, light background, then the same dark.
        for background in ["light", "dark"] {
            await next(t, "132 columns, \(background)") { g in
                g.allSatisfy { $0.count == 132 }
                    && g[2].hasPrefix("  This is 132 column mode, \(background) background.")
                    && g[19].hasPrefix(String(repeating: " ", count: 19) + "This is 132 column mode")
            }
            await next(t, "80 columns, \(background)") { g in
                g[2].hasPrefix("  This is 80 column mode, \(background) background.")
                    && g[19].hasPrefix(String(repeating: " ", count: 19) + "This is 80 column mode")
            }
            // SwiftTerm bug: DECCOLM calls resetToInitialState(), which turns
            // allow80To132 back off, so the `CSI ? 3 l` that should return to
            // 80 columns is ignored and the terminal stays 132 wide. When this
            // starts passing, SwiftTerm has fixed it: drop the expectation.
            XCTExpectFailure("SwiftTerm stays at 132 columns after DECCOLM") {
                XCTAssertEqual(t.size.cols, 80)
            }
        }

        // Scrolling regions: the final screen of each pass, soft then jump.
        for kind in ["Soft", "Jump"] {
            await next(t, "\(kind) scroll in a two-line region") { g in
                g[11].hasPrefix("Push <RETURN>")
                    && g[12].hasPrefix("\(kind) scroll down region [12..13] size 2 Line 29")
            }
            await next(t, "\(kind) scroll over the whole screen") { g in
                g[0].hasPrefix("Push <RETURN>")
                    && (1...23).allSatisfy { self.trim(g[$0]) == ("\(kind) scroll down region [1..24] size 24 Line \(30 - $0)") }
            }
        }

        await next(t, "origin mode, relative") { g in
            g[22].hasPrefix("This line should be the one above the bottom of the screen.")
                && g[23].hasPrefix("Origin mode test. This line should be at the bottom of the screen.")
        }
        await next(t, "origin mode, absolute") { g in
            g[0].hasPrefix("This line should be at the top of the screen.")
                && g[23].hasPrefix("Origin mode test. This line should be at the bottom of the screen.")
        }

        // Graphic rendition: each label drawn in the attributes it names.
        await next(t, "the rendition pattern") { g in
            g[0].contains("Graphic rendition test pattern:") && g[22].hasPrefix("Dark background.")
        }
        func style(_ col: Int, _ row: Int) -> CharacterStyle { t.attribute(col: col, row: row)?.style ?? [] }
        XCTAssertEqual(style(0, 3), [], "vanilla\n\(t.dump)")
        XCTAssertTrue(style(39, 3).contains(.bold), "bold\n\(t.dump)")
        XCTAssertTrue(style(5, 5).contains(.underline), "underline\n\(t.dump)")
        XCTAssertTrue(style(0, 7).contains(.blink), "blink\n\(t.dump)")
        XCTAssertTrue(style(0, 11).contains(.inverse), "negative\n\(t.dump)")
        let all = style(44, 17)
        XCTAssertTrue(all.isSuperset(of: [.bold, .underline, .blink, .inverse]),
                      "bold underline blink negative: \(all)\n\(t.dump)")

        await next(t, "the rendition pattern, light") { g in g[22].hasPrefix("Light background.") }

        // Save/restore cursor, and the DEC special graphics set.
        await next(t, "save/restore and line drawing") { g in
            (0...3).allSatisfy { self.trim(g[$0]) == ("AAAAA") }
                && self.trim(g[9]) == ("stars:     " + Array(repeating: "**********", count: 5).joined(separator: "  "))
                && self.trim(g[11]) == ("line:      " + Array(repeating: String(repeating: "─", count: 10), count: 5).joined(separator: "  "))
                && self.trim(g[13]) == ("x'es:      " + Array(repeating: "xxxxxxxxxx", count: 5).joined(separator: "  "))
                && self.trim(g[15]) == ("diamonds:  " + Array(repeating: String(repeating: "◆", count: 10), count: 5).joined(separator: "  "))
        }
        XCTAssertTrue(style(24, 9).contains(.bold), "bold stars\n\(t.dump)")
        XCTAssertTrue(style(60, 13).contains(.inverse), "reversed x'es\n\(t.dump)")
    }

    // MARK: Menu 8 — VT102 insert/delete

    func testInsertAndDelete() async throws {
        let t = try await open("8")
        defer { t.stop() }

        func letter(_ row: Int) -> Character { Character(UnicodeScalar(UInt8(ascii: "A") + UInt8(row))) }

        await settle(t, "the accordion, full") { g in
            return (0..<24).allSatisfy { row in
                row == 3
                    ? g[3] == "Screen accordion test (Insert & Delete Line). Push <RETURN>" + String(repeating: "D", count: 21)
                    : g[row] == String(repeating: letter(row), count: 80)
            }
        }

        await next(t, "the accordion, collapsed") { g in
            g[0] == String(repeating: "A", count: 80)
                && self.trim(g[1]) == ("Top line: A's, bottom line: X's, this line, nothing more. Push <RETURN>")
                && (2...22).allSatisfy { self.trim(g[$0]) == ("") }
                && g[23] == String(repeating: "X", count: 80)
        }

        await next(t, "insert mode") { g in g[0] == "A" + String(repeating: "*", count: 78) + "B" }
        await next(t, "delete character") { g in self.trim(g[0]) == ("AB") }

        // Each row one shorter than the one above: insert character pushed the
        // right column off one more cell per row, then delete character
        // pulled the rest back.
        await next(t, "the right column staggered by insert") { g in
            (0..<24).allSatisfy { self.rightmost(g[$0]) == 78 - $0 }
        }
        await next(t, "the right column staggered by delete") { g in
            (0..<24).allSatisfy { self.rightmost(g[$0]) == 38 - $0 }
        }

        await next(t, "ANSI insert character") { g in
            let expected = ("  " + (0..<26).map { String(Character(UnicodeScalar(UInt8(ascii: "A") + UInt8($0)))) }.joined(separator: " "))
            return self.trim(g[2]) == expected && self.trim(g[5]) == expected
        }
    }
}
