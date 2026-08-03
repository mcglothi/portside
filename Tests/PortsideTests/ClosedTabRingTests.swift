import Foundation
import XCTest
@testable import Portside

final class ClosedTabRingTests: XCTestCase {

    private func makeTab(_ title: String,
                         customTitle: String? = nil,
                         paneCount: Int = 1,
                         closedAt: Date = Date()) -> ClosedTab {
        ClosedTab(plan: RestorePlan.TabPlan(root: .leaf(.localShell(includedInMultiExec: false))),
                  title: title,
                  customTitle: customTitle,
                  paneCount: paneCount,
                  closedAt: closedAt)
    }

    // MARK: - Ordering

    func testStartsEmpty() {
        XCTAssertTrue(ClosedTabRing().isEmpty)
        XCTAssertTrue(ClosedTabRing().mostRecentFirst.isEmpty)
    }

    /// The menu lists newest first; the ring stores newest last. Getting this
    /// backwards puts the tab you just closed at the bottom of the list.
    func testListsMostRecentFirst() {
        var ring = ClosedTabRing()
        ring.record(makeTab("first"))
        ring.record(makeTab("second"))
        ring.record(makeTab("third"))

        XCTAssertEqual(ring.mostRecentFirst.map(\.title), ["third", "second", "first"])
    }

    func testTakeMostRecentReturnsTheNewest() {
        var ring = ClosedTabRing()
        ring.record(makeTab("older"))
        ring.record(makeTab("newer"))

        XCTAssertEqual(ring.takeMostRecent()?.title, "newer")
        XCTAssertEqual(ring.entries.map(\.title), ["older"])
    }

    func testTakeMostRecentOnEmptyRingReturnsNil() {
        var ring = ClosedTabRing()
        XCTAssertNil(ring.takeMostRecent())
    }

    // MARK: - Eviction

    func testDropsOldestPastTheLimit() {
        var ring = ClosedTabRing(limit: 3)
        for name in ["a", "b", "c", "d", "e"] { ring.record(makeTab(name)) }

        XCTAssertEqual(ring.entries.map(\.title), ["c", "d", "e"])
    }

    /// A limit of zero means keep nothing. Worth pinning because the eviction
    /// is a loop precisely so it cannot be satisfied by a single removal.
    func testLimitOfZeroKeepsNothing() {
        var ring = ClosedTabRing(limit: 0)
        ring.record(makeTab("a"))

        XCTAssertTrue(ring.isEmpty)
    }

    // MARK: - Taking one out

    /// Reaching past the most recent entry is the whole point of the menu.
    func testTakesASpecificEntryFromTheMiddle() {
        var ring = ClosedTabRing()
        ring.record(makeTab("a"))
        ring.record(makeTab("b"))
        ring.record(makeTab("c"))
        let middle = ring.entries[1].id

        XCTAssertEqual(ring.take(id: middle)?.title, "b")
        XCTAssertEqual(ring.entries.map(\.title), ["a", "c"])
    }

    /// A tab that is open again is not a tab you can reopen — otherwise the
    /// menu keeps offering it and each pick spawns another copy.
    func testTakingTheSameEntryTwiceReturnsNil() {
        var ring = ClosedTabRing()
        ring.record(makeTab("a"))
        let id = ring.entries[0].id

        XCTAssertNotNil(ring.take(id: id))
        XCTAssertNil(ring.take(id: id))
    }

    func testClearForgetsEverything() {
        var ring = ClosedTabRing()
        ring.record(makeTab("a"))
        ring.record(makeTab("b"))

        ring.clear()

        XCTAssertTrue(ring.isEmpty)
    }

    // MARK: - Labelling

    func testSinglePaneTabShowsJustItsTitle() {
        XCTAssertEqual(makeTab("hopper").menuLabel, "hopper")
    }

    /// Two tabs closed minutes apart on the same host are indistinguishable by
    /// name, so a split has to say how many panes it brings back.
    func testSplitTabSaysHowManyPanes() {
        XCTAssertEqual(makeTab("hopper", paneCount: 3).menuLabel, "hopper — 3 panes")
    }

    /// `closedAt` was recorded on every close and read by nothing, which left
    /// two same-named tabs in the menu still telling you nothing about which is
    /// which — the very problem the pane count was added to solve.
    func testTheMenuEntryAlsoSaysWhenItWasClosed() {
        let now = Date()
        let tab = makeTab("hopper", closedAt: now.addingTimeInterval(-3600))
        XCTAssertEqual(tab.menuEntry(now: now), "hopper · 1 hour ago")
    }

    func testAPaneCountAndATimeCanAppearTogether() {
        let now = Date()
        let tab = makeTab("hopper", paneCount: 3, closedAt: now.addingTimeInterval(-120))
        XCTAssertEqual(tab.menuEntry(now: now), "hopper — 3 panes · 2 minutes ago")
    }

    /// A renamed tab must come back under the name it was closed under, but a
    /// tab that never had one must not get its host's live title pinned as a
    /// custom name — that would stop it following the terminal.
    func testCustomTitleIsTrackedSeparatelyFromTheDisplayedTitle() {
        let renamed = makeTab("prod rollout", customTitle: "prod rollout")
        let plain = makeTab("hopper")

        XCTAssertEqual(renamed.customTitle, "prod rollout")
        XCTAssertNil(plain.customTitle)
        XCTAssertEqual(plain.title, "hopper", "still shown in the menu under its live title")
    }
}
