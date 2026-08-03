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
        return WorkspaceSnapshot.TabSnapshot(
            root: .split(orientation: .horizontal, children: ids.map { leaf(.host($0)) })
        )
    }

    // MARK: - Model

    func testAGroupKnowsItsMembersAndSize() {
        let a = UUID(), b = UUID()
        var root = grid([a, b])
        // Mix in a local shell: it counts as a pane but is not a member host.
        root = WorkspaceSnapshot.TabSnapshot(root: .split(
            orientation: .horizontal,
            children: [leaf(.host(a)), leaf(.host(b)), leaf(.localShell)]))
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

    // MARK: - Folders

    /// `SessionGroup.folder` and the sidebar's folder rendering both shipped,
    /// but nothing could write the field: the save sheet passed a name only,
    /// and groups aren't draggable. Every group sat at the root regardless.
    func testAGroupCanBeFiledInAFolder() {
        let store = SessionStore(fileURL: tempURL, seedsFromSSHConfig: false)
        let group = SessionGroup(name: "Splunk", layout: grid([UUID(), UUID()]))
        store.upsert(group)
        XCTAssertEqual(store.group(id: group.id)?.folder, "")

        store.move(groupID: group.id, toFolder: "prod/observability")

        XCTAssertEqual(store.group(id: group.id)?.folder, "prod/observability")
        XCTAssertTrue(store.folders.contains("prod/observability"),
                      "the folder must exist even when a group is the only thing in it")
    }

    func testSavingIntoAFolderNormalizesAndRegistersIt() {
        let store = SessionStore(fileURL: tempURL, seedsFromSSHConfig: false)
        // As typed into the save sheet by someone who thinks in paths.
        store.upsert(SessionGroup(name: "Splunk", folder: "/prod/web/", layout: grid([UUID()])))

        XCTAssertEqual(store.groups.first?.folder, "prod/web",
                       "a stray slash must not fork a near-duplicate folder")
        XCTAssertTrue(store.folders.contains("prod/web"))
    }

    /// Renaming a folder rewrote hosts and the folder list but never groups,
    /// so the group was left pointing at a path nothing else referenced — the
    /// old folder stayed in the sidebar containing only orphans.
    func testGroupsFollowAFolderRename() {
        let store = SessionStore(fileURL: tempURL, seedsFromSSHConfig: false)
        store.upsert(SessionGroup(name: "Splunk", folder: "prod/web", layout: grid([UUID()])))
        store.upsert(SessionGroup(name: "Nested", folder: "prod/web/edge", layout: grid([UUID()])))

        store.renameFolder("prod/web", to: "frontend")

        XCTAssertEqual(store.groups.first { $0.name == "Splunk" }?.folder, "prod/frontend")
        XCTAssertEqual(store.groups.first { $0.name == "Nested" }?.folder, "prod/frontend/edge",
                       "subfolders below the renamed one must move with it")
    }

    func testGroupsSurviveTheirFolderBeingDeleted() {
        let store = SessionStore(fileURL: tempURL, seedsFromSSHConfig: false)
        store.upsert(SessionGroup(name: "Splunk", folder: "prod/web", layout: grid([UUID()])))

        store.deleteFolder("prod/web")

        XCTAssertEqual(store.groups.count, 1, "deleting a folder must not delete its groups")
        XCTAssertEqual(store.groups.first?.folder, "prod",
                       "they move up to the parent, as hosts do")
    }

    func testAFiledGroupPersists() {
        let group = SessionGroup(name: "Splunk", layout: grid([UUID()]))
        let store = SessionStore(fileURL: tempURL, seedsFromSSHConfig: false)
        store.upsert(group)
        store.move(groupID: group.id, toFolder: "prod")

        XCTAssertEqual(SessionStore(fileURL: tempURL, seedsFromSSHConfig: false)
            .group(id: group.id)?.folder, "prod")
    }

    // MARK: - Favorites

    /// `isFavorite` shipped on the model and was read by nothing but the
    /// sidebar's cache key — no way to set it, nowhere it changed anything.
    func testAFavoritedGroupReachesTheWelcomeScreen() {
        let store = SessionStore(fileURL: tempURL, seedsFromSSHConfig: false)
        let plain = SessionGroup(name: "Scratch", layout: grid([UUID()]))
        let starred = SessionGroup(name: "Splunk", layout: grid([UUID()]))
        store.upsert(plain)
        store.upsert(starred)
        XCTAssertTrue(store.favoriteGroups.isEmpty)

        store.toggleFavorite(groupID: starred.id)

        XCTAssertEqual(store.favoriteGroups.map(\.name), ["Splunk"])
    }

    func testFavoritesAreAlphabeticalAndToggleBack() {
        let store = SessionStore(fileURL: tempURL, seedsFromSSHConfig: false)
        for name in ["zeta", "Alpha", "mid"] {
            var g = SessionGroup(name: name, layout: grid([UUID()]))
            g.isFavorite = true
            store.upsert(g)
        }
        XCTAssertEqual(store.favoriteGroups.map(\.name), ["Alpha", "mid", "zeta"])

        let alpha = try? XCTUnwrap(store.groups.first { $0.name == "Alpha" })
        store.toggleFavorite(groupID: alpha!.id)

        XCTAssertEqual(store.favoriteGroups.map(\.name), ["mid", "zeta"])
    }

    func testFavoritingPersists() {
        let group = SessionGroup(name: "Splunk", layout: grid([UUID()]))
        let store = SessionStore(fileURL: tempURL, seedsFromSSHConfig: false)
        store.upsert(group)
        store.toggleFavorite(groupID: group.id)

        XCTAssertEqual(SessionStore(fileURL: tempURL, seedsFromSSHConfig: false)
            .favoriteGroups.map(\.name), ["Splunk"])
    }

    func testTogglingAnUnknownGroupWritesNothing() {
        let store = SessionStore(fileURL: tempURL, seedsFromSSHConfig: false)
        store.upsert(SessionGroup(name: "Splunk", layout: grid([UUID()])))

        store.toggleFavorite(groupID: UUID())

        XCTAssertTrue(store.favoriteGroups.isEmpty)
    }

    /// Drag drops several rows at once, so the batch form must be one write
    /// and must leave alone whatever wasn't dragged.
    func testMovingSeveralGroupsAtOnce() {
        let store = SessionStore(fileURL: tempURL, seedsFromSSHConfig: false)
        let a = SessionGroup(name: "A", layout: grid([UUID()]))
        let b = SessionGroup(name: "B", layout: grid([UUID()]))
        let untouched = SessionGroup(name: "C", folder: "lab", layout: grid([UUID()]))
        for g in [a, b, untouched] { store.upsert(g) }

        store.move(groupIDs: [a.id, b.id], toFolder: "staging")

        XCTAssertEqual(store.group(id: a.id)?.folder, "staging")
        XCTAssertEqual(store.group(id: b.id)?.folder, "staging")
        XCTAssertEqual(store.group(id: untouched.id)?.folder, "lab")
        XCTAssertTrue(store.folders.contains("staging"))
    }

    func testDraggingAGroupToTheTopLevelDoesNotInventAFolder() {
        let store = SessionStore(fileURL: tempURL, seedsFromSSHConfig: false)
        let group = SessionGroup(name: "A", folder: "lab", layout: grid([UUID()]))
        store.upsert(group)

        store.move(groupIDs: [group.id], toFolder: "")

        XCTAssertEqual(store.group(id: group.id)?.folder, "")
        XCTAssertFalse(store.folders.contains(""), "the top level is not a folder")
    }

    // MARK: - The sidebar's folder badge

    /// The badge counted hosts only, so a folder made to hold groups showed no
    /// number at all — indistinguishable from an empty folder.
    func testAFolderOfGroupsIsCounted() {
        let store = SessionStore(fileURL: tempURL, seedsFromSSHConfig: false)
        store.upsert(SessionGroup(name: "Splunk", folder: "runbooks", layout: grid([UUID()])))
        store.upsert(SessionGroup(name: "Edge", folder: "runbooks", layout: grid([UUID()])))

        XCTAssertEqual(store.itemCount(inFolder: "runbooks"), 2)
    }

    func testHostsAndGroupsAreCountedTogether() {
        let store = SessionStore(fileURL: tempURL, seedsFromSSHConfig: false)
        store.upsert(SessionEntry(name: "web-01", folder: "prod", hostname: "w.example.com"))
        store.upsert(SessionEntry(name: "web-02", folder: "prod", hostname: "w2.example.com"))
        store.upsert(SessionGroup(name: "Splunk", folder: "prod", layout: grid([UUID()])))

        XCTAssertEqual(store.itemCount(inFolder: "prod"), 3)
    }

    /// Hosts already counted through subfolders; groups have to match, or a
    /// parent's number would disagree with what expanding it shows.
    func testSubfoldersCountTowardsTheParent() {
        let store = SessionStore(fileURL: tempURL, seedsFromSSHConfig: false)
        store.upsert(SessionEntry(name: "web-01", folder: "prod/web", hostname: "w.example.com"))
        store.upsert(SessionGroup(name: "Splunk", folder: "prod/observability", layout: grid([UUID()])))
        store.upsert(SessionGroup(name: "Top", folder: "prod", layout: grid([UUID()])))

        XCTAssertEqual(store.itemCount(inFolder: "prod"), 3)
        XCTAssertEqual(store.itemCount(inFolder: "prod/observability"), 1)
    }

    /// "prod" must not swallow "production" — the reason the prefix carries a
    /// trailing slash.
    func testASimilarlyNamedSiblingIsNotCounted() {
        let store = SessionStore(fileURL: tempURL, seedsFromSSHConfig: false)
        store.upsert(SessionGroup(name: "A", folder: "prod", layout: grid([UUID()])))
        store.upsert(SessionGroup(name: "B", folder: "production", layout: grid([UUID()])))
        store.upsert(SessionEntry(name: "web", folder: "production", hostname: "w.example.com"))

        XCTAssertEqual(store.itemCount(inFolder: "prod"), 1)
        XCTAssertEqual(store.itemCount(inFolder: "production"), 2)
    }

    func testAnEmptyFolderCountsZero() {
        let store = SessionStore(fileURL: tempURL, seedsFromSSHConfig: false)
        store.createFolder("lab")
        XCTAssertEqual(store.itemCount(inFolder: "lab"), 0)
    }

}

/// Saving and updating a group from the tab, rather than only the File menu.
@MainActor
final class GroupSaveFromTabTests: XCTestCase {
    private var tempURL: URL!

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-gsave-\(UUID().uuidString).json")
    }

    override func tearDown() {
        for suffix in ["", ".local", ".history"] {
            let u = suffix.isEmpty ? tempURL!
                : tempURL.deletingPathExtension().appendingPathExtension("\(suffix.dropFirst()).json")
            try? FileManager.default.removeItem(at: u)
        }
        super.tearDown()
    }

    /// A manager wired to a store the way the app wires them.
    private func wired(_ store: SessionStore) -> SessionManager {
        let manager = SessionManager()
        manager.onGroupLayoutChange = { [weak store] id, layout, grid in
            store?.updateLayout(groupID: id, layout: layout, wasGridView: grid)
        }
        return manager
    }

    func testUpdatingWritesTheCurrentArrangementBackWithoutClosing() throws {
        // You shouldn't have to close a tab to checkpoint it.
        let store = SessionStore(fileURL: tempURL)
        let manager = wired(store)
        defer { for s in manager.sessions { s.shutdown() } }

        manager.openLocalShell()
        let group = try XCTUnwrap(manager.groupFromSelectedTab(named: "Splunk"))
        store.upsert(group)
        manager.selectedTab?.groupID = group.id
        XCTAssertEqual(store.group(id: group.id)?.paneCount, 1)

        manager.splitActivePane(.horizontal)          // rearrange
        manager.captureGroupLayoutIfLinked(try XCTUnwrap(manager.selectedTab))

        XCTAssertEqual(store.group(id: group.id)?.paneCount, 2,
                       "the new arrangement should be saved without closing the tab")
    }

    func testUpdatingATabWithNoGroupWritesNothing() throws {
        let store = SessionStore(fileURL: tempURL)
        let manager = wired(store)
        defer { for s in manager.sessions { s.shutdown() } }
        manager.openLocalShell()

        manager.captureGroupLayoutIfLinked(try XCTUnwrap(manager.selectedTab))

        XCTAssertTrue(store.groups.isEmpty, "an ordinary tab must not invent a group")
    }

    func testSavingAsANewGroupFromALinkedTabRelinksToTheNewOne() throws {
        // Forking: "Save as New Group…" from a tab that's already a group. The
        // tab should now belong to the new one, or the next close would write
        // this layout back over the original.
        let store = SessionStore(fileURL: tempURL)
        let manager = wired(store)
        defer { for s in manager.sessions { s.shutdown() } }

        manager.openLocalShell()
        let first = try XCTUnwrap(manager.groupFromSelectedTab(named: "Splunk"))
        store.upsert(first)
        manager.selectedTab?.groupID = first.id

        let second = try XCTUnwrap(manager.groupFromSelectedTab(named: "Splunk copy"))
        store.upsert(second)
        manager.selectedTab?.groupID = second.id

        XCTAssertEqual(store.groups.count, 2)
        XCTAssertEqual(manager.selectedTab?.groupID, second.id)

        manager.splitActivePane(.horizontal)
        manager.captureGroupLayoutIfLinked(try XCTUnwrap(manager.selectedTab))

        XCTAssertEqual(store.group(id: second.id)?.paneCount, 2, "the fork took the change")
        XCTAssertEqual(store.group(id: first.id)?.paneCount, 1, "the original is untouched")
    }
}
