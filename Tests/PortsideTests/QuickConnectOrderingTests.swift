import XCTest
@testable import Portside

/// What ⌘K offers you, and in what order.
///
/// The ordering rule is the interesting part rather than the fuzzy scorer:
/// groups joined the palette late, and the risk of that change was never that
/// groups wouldn't appear — it was that they'd appear *first* and break "⌘K,
/// Return" as a reconnect.
@MainActor
final class QuickConnectOrderingTests: XCTestCase {

    private func host(_ name: String, folder: String = "") -> SessionEntry {
        SessionEntry(name: name, folder: folder, hostname: "\(name).example.com")
    }

    private func group(_ name: String, folder: String = "", panes: Int = 2) -> SessionGroup {
        let ids = (0..<panes).map { _ in UUID() }
        return SessionGroup(name: name, folder: folder, layout: WorkspaceSnapshot.TabSnapshot(
            root: .split(orientation: .horizontal, children: ids.map {
                .leaf(WorkspaceSnapshot.Leaf(kind: .host($0), includedInMultiExec: true))
            })
        ))
    }

    private func names(_ items: [QuickConnectView.Item]) -> [String] {
        items.map(\.name)
    }

    // MARK: - Empty query

    func testRecentsStayFirstSoReturnStillReconnects() {
        let recent = host("web-04")
        let items = QuickConnectView.ordered(
            query: "",
            entries: [recent, host("aardvark")],
            groups: [group("Splunk")],
            recents: [recent]
        )

        XCTAssertEqual(names(items).first, "web-04",
                       "⌘K then Return must still be the fast reconnect it was")
    }

    func testGroupsSitBetweenTheRecentsAndTheRestOfTheLibrary() {
        let recent = host("web-04")
        let items = QuickConnectView.ordered(
            query: "",
            entries: [recent, host("aardvark"), host("zebra")],
            groups: [group("Splunk"), group("Edge")],
            recents: [recent]
        )

        // Alphabetical within each band; a recent host is not repeated below.
        XCTAssertEqual(names(items), ["web-04", "Edge", "Splunk", "aardvark", "zebra"])
    }

    func testAGroupIsOfferedEvenWithNoHostsAtAll() {
        let items = QuickConnectView.ordered(
            query: "", entries: [], groups: [group("Splunk")], recents: []
        )
        XCTAssertEqual(names(items), ["Splunk"])
    }

    // MARK: - With a query

    func testHostsAndGroupsCompeteOnTheSameScale() {
        // No bonus either way: an exact-ish group name should be able to beat
        // a host, and a better host match should be able to beat a group.
        let items = QuickConnectView.ordered(
            query: "splunk",
            entries: [host("splunk-01"), host("unrelated")],
            groups: [group("Splunk")],
            recents: []
        )

        XCTAssertEqual(Set(names(items)), ["splunk-01", "Splunk"])
        XCTAssertFalse(names(items).contains("unrelated"))
    }

    func testANonMatchingGroupIsFilteredOut() {
        let items = QuickConnectView.ordered(
            query: "zzz", entries: [host("web")], groups: [group("Splunk")], recents: []
        )
        XCTAssertTrue(items.isEmpty)
    }

    func testAGroupMatchesOnItsFolderToo() {
        let items = QuickConnectView.ordered(
            query: "observ",
            entries: [],
            groups: [group("SG-1", folder: "prod/observability")],
            recents: []
        )
        XCTAssertEqual(names(items), ["SG-1"])
    }

    // MARK: - Ranking

    func testAGroupsNameOutranksItsFolder() {
        let byName = QuickConnectView.rank(group("splunk", folder: "prod"), query: "splunk")
        let byFolder = QuickConnectView.rank(group("SG-1", folder: "splunk"), query: "splunk")
        XCTAssertNotNil(byName)
        XCTAssertNotNil(byFolder)
        XCTAssertGreaterThan(byName!, byFolder!,
                             "what a thing is called should beat where it's filed")
    }

    func testRankingIsCaseInsensitive() {
        XCTAssertNotNil(QuickConnectView.rank(group("Splunk"), query: "SPL"))
    }
}
