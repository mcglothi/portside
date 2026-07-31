import XCTest
@testable import Portside

/// Saved host groups: the model, its persistence, and the launch path.
final class SessionGroupTests: XCTestCase {
    private var tempURL: URL!

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-group-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        try? FileManager.default.removeItem(
            at: tempURL.deletingPathExtension().appendingPathExtension("history.json"))
        super.tearDown()
    }

    private func host(_ name: String) -> SessionEntry {
        SessionEntry(name: name, folder: "", hostname: "\(name).example.com")
    }

    private func leaf(_ kind: WorkspaceSnapshot.Leaf.Kind) -> WorkspaceSnapshot.PaneSnapshot {
        .leaf(WorkspaceSnapshot.Leaf(kind: kind, includedInMultiExec: true))
    }

    /// A grid of `ids` split evenly, the shape "save these eight boxes" makes.
    private func grid(_ ids: [UUID]) -> WorkspaceSnapshot.TabSnapshot {
        let children = ids.map { leaf(.host($0)) }
        let fractions = Array(repeating: CGFloat(1.0 / Double(ids.count)), count: ids.count)
        return WorkspaceSnapshot.TabSnapshot(
            root: .split(orientation: .horizontal, children: children, fractions: fractions)
        )
    }

    // MARK: - Model

    func testAGroupKnowsItsMembersAndSize() {
        let a = UUID(), b = UUID()
        var root = grid([a, b])
        // Mix in a local shell: it counts as a pane but is not a member host.
        root = WorkspaceSnapshot.TabSnapshot(root: .split(
            orientation: .horizontal,
            children: [leaf(.host(a)), leaf(.host(b)), leaf(.localShell)],
            fractions: [0.34, 0.33, 0.33]))
        let group = SessionGroup(name: "Splunk", layout: root)

        XCTAssertEqual(group.memberEntryIDs, [a, b])
        XCTAssertEqual(group.paneCount, 3, "a local shell is a pane even though it isn't a host")
    }

    // MARK: - Persistence

    func testGroupsSurviveAReload() {
        let store = SessionStore(fileURL: tempURL)
        let a = host("web-01")
        store.upsert(a)
        store.upsert(SessionGroup(name: "Splunk", folder: "prod", layout: grid([a.id])))

        let reloaded = SessionStore(fileURL: tempURL)
        XCTAssertEqual(reloaded.groups.count, 1)
        XCTAssertEqual(reloaded.groups.first?.name, "Splunk")
        XCTAssertEqual(reloaded.groups.first?.folder, "prod")
        XCTAssertEqual(reloaded.groups.first?.memberEntryIDs, [a.id])
    }

    func testAGroupWithAnUnreadableLayoutDoesNotSinkTheLibrary() throws {
        // `layout` is the one field with no sensible default. A group that
        // can't decode must drop itself, not take the hosts down with it.
        let json = """
        {"entries":[],"macros":[],
         "groups":[{"id":"\(UUID().uuidString)","name":"broken"}]}
        """.data(using: .utf8)!
        try json.write(to: tempURL)

        let store = SessionStore(fileURL: tempURL)
        XCTAssertNil(store.loadFailure, "one bad group must not fail the whole load")
        XCTAssertTrue(store.groups.isEmpty)
    }

    func testAGroupMissingNewerFieldsStillDecodes() throws {
        // The tolerant-decoder guarantee: a field added later must not make
        // old groups fail the entire library load.
        let id = UUID()
        let json = """
        {"entries":[],"macros":[],
         "groups":[{"id":"\(id.uuidString)","name":"old",
                    "layout":{"root":{"leaf":{"_0":{"kind":{"localShell":{}},
                                                    "includedInMultiExec":true}}}}}]}
        """.data(using: .utf8)!
        try json.write(to: tempURL)

        let store = SessionStore(fileURL: tempURL)
        XCTAssertEqual(store.groups.count, 1)
        XCTAssertEqual(store.groups.first?.folder, "", "missing folder defaults")
        XCTAssertFalse(store.groups.first?.isFavorite ?? true, "missing flag defaults")
    }

    func testAWorkspaceSnapshotWrittenBeforeGroupsExistedStillDecodes() throws {
        // `TabSnapshot.groupID` was added after the fact. Optional, so the
        // synthesized decoder tolerates its absence — a non-optional here would
        // have failed every existing restore.
        let json = """
        {"tabs":[{"root":{"leaf":{"_0":{"kind":{"localShell":{}},
                                        "includedInMultiExec":true}}}}],
         "selectedTabIndex":0,"wasGridView":false}
        """.data(using: .utf8)!

        let snapshot = try JSONDecoder().decode(WorkspaceSnapshot.self, from: json)
        XCTAssertEqual(snapshot.tabs.count, 1)
        XCTAssertNil(snapshot.tabs.first?.groupID)
    }

    // MARK: - Store operations

    func testUpdatingALayoutLeavesTheNameAndFolderAlone() {
        let store = SessionStore(fileURL: tempURL)
        let a = host("web-01"), b = host("web-02")
        var group = SessionGroup(name: "Splunk", folder: "prod", layout: grid([a.id]))
        store.upsert(group)
        group = try! XCTUnwrap(store.groups.first)

        store.updateLayout(groupID: group.id, layout: grid([a.id, b.id]), wasGridView: true)

        let updated = store.groups.first
        XCTAssertEqual(updated?.name, "Splunk")
        XCTAssertEqual(updated?.folder, "prod")
        XCTAssertEqual(updated?.memberEntryIDs, [a.id, b.id])
        XCTAssertEqual(updated?.wasGridView, true)
    }

    func testUpdatingAnUnknownGroupWritesNothing() {
        // Closing an ordinary tab must not invent a group.
        let store = SessionStore(fileURL: tempURL)
        store.updateLayout(groupID: UUID(), layout: grid([UUID()]), wasGridView: false)
        XCTAssertTrue(store.groups.isEmpty)
    }

    // MARK: - Launch

    @MainActor
    func testLaunchingAGroupOpensOneTabWithEveryMember() throws {
        let store = SessionStore(fileURL: tempURL)
        let a = host("web-01"), b = host("web-02")
        store.upsert(a); store.upsert(b)
        let group = SessionGroup(name: "Splunk", layout: grid([a.id, b.id]))

        let manager = SessionManager()
        defer { for s in manager.sessions { s.shutdown() } }
        let result = manager.launch(group) { id in store.entry(id: id) }

        XCTAssertEqual(result.opened, 2)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(manager.tabs.count, 1, "a group opens as one tab, not one tab per host")
        XCTAssertEqual(manager.selectedTab?.groupID, group.id,
                       "the tab stays linked so closing it writes back")
    }

    @MainActor
    func testAGroupLaunchesDisarmed() throws {
        // Same rule workspace restore follows: the grid comes back assembled,
        // and arming stays a deliberate act.
        let store = SessionStore(fileURL: tempURL)
        let a = host("web-01")
        store.upsert(a)

        let manager = SessionManager()
        defer { for s in manager.sessions { s.shutdown() } }
        manager.launch(SessionGroup(name: "Splunk", layout: grid([a.id]))) { store.entry(id: $0) }

        XCTAssertEqual(manager.selectedTab?.broadcastArmed, false)
    }

    @MainActor
    func testADeletedMemberIsSkippedRatherThanFailingTheLaunch() throws {
        // Eight hosts where one was deleted should open seven and say so.
        let store = SessionStore(fileURL: tempURL)
        let a = host("web-01")
        store.upsert(a)
        let goneID = UUID()
        let group = SessionGroup(name: "Splunk", layout: grid([a.id, goneID]))

        let manager = SessionManager()
        defer { for s in manager.sessions { s.shutdown() } }
        let result = manager.launch(group) { id in store.entry(id: id) }

        XCTAssertEqual(result.opened, 1)
        XCTAssertEqual(result.missing, [goneID])
        XCTAssertFalse(result.isComplete)
    }

    @MainActor
    func testAGroupWhoseMembersAreAllGoneOpensNothing() throws {
        let store = SessionStore(fileURL: tempURL)
        let group = SessionGroup(name: "Splunk", layout: grid([UUID(), UUID()]))

        let manager = SessionManager()
        defer { for s in manager.sessions { s.shutdown() } }
        let result = manager.launch(group) { id in store.entry(id: id) }

        XCTAssertEqual(result.opened, 0)
        XCTAssertEqual(result.missing.count, 2)
        XCTAssertTrue(manager.tabs.isEmpty, "no empty tab left behind")
    }

    @MainActor
    func testCapturingTheSelectedTabProducesALaunchableGroup() throws {
        let manager = SessionManager()
        defer { for s in manager.sessions { s.shutdown() } }
        manager.openLocalShell()

        let group = try XCTUnwrap(manager.groupFromSelectedTab(named: "Shells"))
        XCTAssertEqual(group.name, "Shells")
        XCTAssertEqual(group.paneCount, 1)
        XCTAssertTrue(group.memberEntryIDs.isEmpty, "a local shell is not a library host")
    }

    @MainActor
    func testAStartPageCannotBeSavedAsAGroup() {
        // A group that opens nothing is worse than no group.
        let manager = SessionManager()
        manager.openStartTab()
        XCTAssertNil(manager.groupFromSelectedTab(named: "Nothing"))
    }
}
