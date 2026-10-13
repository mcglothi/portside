import XCTest
@testable import Portside

/// The Results section pinned above the dimmed tree while filtering (#56):
/// every match in one place, saying where each lives.
final class SidebarResultsTests: XCTestCase {
    private func host(_ name: String, _ folder: String = "") -> SessionEntry {
        SessionEntry(name: name, folder: folder, hostname: "\(name).example.com")
    }

    func testMatchesAreListedFlatWithWhereTheyLive() {
        let a = host("ora08", "LLB/Linux/Green Zone"), b = host("ora08", "LLB/Linux/Red Zone"),
            c = host("web01"), d = host("db7", "prod")
        let team = host("ora09", "databases")
        var matches = SidebarMatches()
        matches.ids = [a.id, b.id, c.id, team.id]
        let results = SidebarResult.build(matches: matches, own: [a, b, c, d],
                                          shared: [(sourceName: "Team", entries: [team])])
        XCTAssertEqual(results.map(\.entry.name), ["ora08", "ora08", "ora09", "web01"], "by name, natural order")
        XCTAssertEqual(results.map(\.location),
                       ["LLB/Linux/Green Zone", "LLB/Linux/Red Zone", "Team/databases", "Top level"],
                       "same-named hosts told apart by folder; shared ones by source")
        XCTAssertFalse(results.contains { $0.entry.id == d.id }, "only matches")
    }

    func testNoMatchesIsAnEmptySectionNotNone() {
        let results = SidebarResult.build(matches: SidebarMatches(), own: [host("a")], shared: [])
        XCTAssertEqual(results, [], "the section shows \"No matches\" rather than disappearing")
    }

    func testNaturalOrderPutsHost2BeforeHost10() {
        var matches = SidebarMatches()
        let h10 = host("host10"), h2 = host("host2")
        matches.ids = [h10.id, h2.id]
        XCTAssertEqual(SidebarResult.build(matches: matches, own: [h10, h2], shared: []).map(\.entry.name),
                       ["host2", "host10"])
    }

    /// Results rows are host rows, so every host action works on them, and
    /// they carry where the host lives.
    func testResultsNodesAreHostRowsWithALocation() {
        let a = host("ora08", "LLB")
        let node = SidebarNode.results([SidebarResult(entry: a, location: "LLB")])
        XCTAssertTrue(node.isResults)
        XCTAssertFalse(node.isFolder, "not a folder: nothing can be filed into it")
        XCTAssertEqual(node.children.count, 1)
        XCTAssertEqual(node.children[0].entryID, a.id)
        XCTAssertTrue(node.children[0].isEntry)
        XCTAssertEqual(node.children[0].resultLocation, "LLB")
    }
}
