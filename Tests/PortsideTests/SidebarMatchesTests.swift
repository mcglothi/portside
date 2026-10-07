import XCTest
@testable import Portside

final class SidebarMatchesTests: XCTestCase {
    private func entry(_ name: String, folder: String = "") -> SessionEntry {
        SessionEntry(name: name, folder: folder, hostname: "\(name).example.com")
    }

    func testMatchingHostLightsUpItsFolderAndAncestors() {
        let web = entry("web01", folder: "prod/frontend")
        let db = entry("db01", folder: "prod/backend")
        let m = SidebarMatches.compute(query: HostQuery("web"), entries: [web, db],
                                       groups: [], folderPaths: ["empty"])
        XCTAssertEqual(m.ids, [web.id])
        XCTAssertEqual(m.folders, ["prod", "prod/frontend"])
        XCTAssertEqual(m.matchedHostCount, 1)
    }

    func testEmptyFolderMatchesOnItsOwnName() {
        let m = SidebarMatches.compute(query: HostQuery("lab"), entries: [entry("web01")],
                                       groups: [], folderPaths: ["home/lab"])
        XCTAssertTrue(m.ids.isEmpty)
        XCTAssertEqual(m.folders, ["home", "home/lab"])
    }

    func testGroupMatchesOnName() {
        let group = SessionGroup(name: "Splunk Servers", folder: "ops", layout: WorkspaceSnapshot.TabSnapshot(
            root: .leaf(WorkspaceSnapshot.Leaf(kind: .localShell, includedInMultiExec: true))))
        let m = SidebarMatches.compute(query: HostQuery("splunk"), entries: [],
                                       groups: [group], folderPaths: [])
        XCTAssertEqual(m.ids, [group.id])
        XCTAssertEqual(m.folders, ["ops"])
        XCTAssertEqual(m.matchedHostCount, 0)
    }
}
