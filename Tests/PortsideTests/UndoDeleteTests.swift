import XCTest
@testable import Portside

/// Taking back a delete.
///
/// The ring is tested as a value type on its own, because the rule that matters
/// most — eviction is what makes a delete permanent, and therefore what
/// releases the Keychain password — is a pure data rule that shouldn't need a
/// store to state.
final class DeletedItemRingTests: XCTestCase {

    private func host(_ name: String) -> SessionEntry {
        SessionEntry(name: name, folder: "", hostname: "\(name).example.com")
    }

    func testRecordingReturnsNothingUntilTheRingIsFull() {
        var ring = DeletedItemRing(limit: 3)
        for name in ["a", "b", "c"] {
            XCTAssertTrue(ring.record(DeletedItems(hosts: [host(name)])).isEmpty)
        }
        XCTAssertEqual(ring.entries.count, 3)
    }

    /// The eviction *is* the deadline: what falls out of the ring is what the
    /// store may finally delete a password for.
    func testTheOldestIsEvictedAndHandedBack() {
        var ring = DeletedItemRing(limit: 2)
        let first = host("a")
        ring.record(DeletedItems(hosts: [first]))
        ring.record(DeletedItems(hosts: [host("b")]))

        let evicted = ring.record(DeletedItems(hosts: [host("c")]))

        XCTAssertEqual(evicted.count, 1)
        XCTAssertEqual(evicted.first?.hosts.first?.id, first.id)
        XCTAssertEqual(ring.entries.count, 2)
    }

    func testAZeroLimitKeepsNothingAndEvictsImmediately() {
        var ring = DeletedItemRing(limit: 0)
        let evicted = ring.record(DeletedItems(hosts: [host("a")]))
        XCTAssertEqual(evicted.count, 1, "nothing is undoable, so nothing may be held open")
        XCTAssertTrue(ring.isEmpty)
    }

    /// Otherwise a no-op delete would push a real one out of the ring.
    func testAnEmptyBatchIsNotRecorded() {
        var ring = DeletedItemRing(limit: 1)
        ring.record(DeletedItems(hosts: [host("a")]))
        XCTAssertTrue(ring.record(DeletedItems()).isEmpty)
        XCTAssertEqual(ring.entries.count, 1)
        XCTAssertEqual(ring.mostRecent?.hosts.first?.name, "a")
    }

    func testTakingABatchRemovesItFromTheRing() {
        var ring = DeletedItemRing()
        ring.record(DeletedItems(hosts: [host("a")]))
        let id = ring.mostRecent!.id

        XCTAssertNotNil(ring.take(id: id))
        XCTAssertNil(ring.take(id: id), "a host that is back is not one you can restore again")
    }

    func testDrainingEmptiesTheRingAndYieldsEverything() {
        var ring = DeletedItemRing()
        ring.record(DeletedItems(hosts: [host("a")]))
        ring.record(DeletedItems(hosts: [host("b")]))

        let drained = ring.drain()

        XCTAssertEqual(drained.count, 2)
        XCTAssertTrue(ring.isEmpty)
    }

    // MARK: - Menu wording

    func testASingleItemIsNamed() {
        XCTAssertEqual(DeletedItems(hosts: [host("web-01")]).menuLabel, "web-01")
    }

    func testAMixedBatchCountsEachKind() {
        let batch = DeletedItems(
            hosts: [host("a"), host("b")],
            groups: [SessionGroup(name: "G", layout: WorkspaceSnapshot.TabSnapshot(
                root: .leaf(WorkspaceSnapshot.Leaf(kind: .localShell, includedInMultiExec: true))))]
        )
        XCTAssertEqual(batch.menuLabel, "2 hosts and 1 group")
    }
}

/// The store side: what comes back, and what a delete leaves behind.
final class UndoDeleteTests: XCTestCase {
    private var tempURL: URL!

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-undo-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        try? FileManager.default.removeItem(
            at: tempURL.deletingPathExtension().appendingPathExtension("history.json"))
        try? FileManager.default.removeItem(
            at: tempURL.deletingPathExtension().appendingPathExtension("local.json"))
        super.tearDown()
    }

    private func makeStore() -> SessionStore {
        SessionStore(fileURL: tempURL, seedsFromSSHConfig: false)
    }

    private func group(_ name: String, folder: String = "") -> SessionGroup {
        SessionGroup(name: name, folder: folder, layout: WorkspaceSnapshot.TabSnapshot(
            root: .leaf(WorkspaceSnapshot.Leaf(kind: .localShell, includedInMultiExec: true))))
    }

    func testDeletingAHostIsUndoable() {
        let store = makeStore()
        store.upsert(SessionEntry(name: "web-01", folder: "", hostname: "web-01.example.com"))
        let entry = store.entries[0]

        store.delete(entry)
        XCTAssertTrue(store.entries.isEmpty)

        store.undoLastDelete()

        XCTAssertEqual(store.entries.map(\.id), [entry.id])
    }

    /// The folder is the subtle part: deleting the last host in one can leave
    /// nothing anchoring it, so restoring without re-creating it would silently
    /// drop the host at the top level — an undo that doesn't undo.
    func testUndoRestoresTheFolderTheHostWasIn() {
        let store = makeStore()
        store.upsert(SessionEntry(name: "web-01", folder: "prod/web", hostname: "w.example.com"))
        let entry = store.entries[0]

        store.delete(entry)
        store.undoLastDelete()

        XCTAssertEqual(store.entries.first?.folder, "prod/web")
        XCTAssertTrue(store.folders.contains("prod/web"))
    }

    func testAMixedDeleteComesBackAsOne() {
        let store = makeStore()
        store.upsert(SessionEntry(name: "web-01", folder: "", hostname: "w.example.com"))
        store.upsert(group("Edge caches"))
        let entryID = store.entries[0].id
        let groupID = store.groups[0].id

        store.delete(entryIDs: [entryID], groupIDs: [groupID], macroIDs: [])
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(store.groups.isEmpty)

        store.undoLastDelete()

        XCTAssertEqual(store.entries.map(\.id), [entryID])
        XCTAssertEqual(store.groups.map(\.id), [groupID])
        XCTAssertTrue(store.deletedItems.isEmpty, "one delete, one undo")
    }

    func testDeletingAGroupIsUndoable() {
        let store = makeStore()
        store.upsert(group("Edge caches", folder: "lab"))
        let id = store.groups[0].id

        store.delete(store.groups[0])
        store.undoLastDelete()

        XCTAssertEqual(store.groups.map(\.id), [id])
        XCTAssertEqual(store.groups.first?.folder, "lab")
    }

    func testDeletingAMacroIsUndoable() {
        let store = makeStore()
        store.upsert(Macro(name: "restart", text: "systemctl restart nginx"))
        let id = store.macros[0].id

        store.delete(store.macros[0])
        XCTAssertTrue(store.macros.isEmpty)
        store.undoLastDelete()

        XCTAssertEqual(store.macros.map(\.id), [id])
    }

    func testUndoingReachesPastTheMostRecentDelete() {
        let store = makeStore()
        for name in ["a", "b"] {
            store.upsert(SessionEntry(name: name, folder: "", hostname: "\(name).example.com"))
        }
        let a = store.entries.first { $0.name == "a" }!
        let b = store.entries.first { $0.name == "b" }!
        store.delete(a)
        store.delete(b)

        // The menu lists both; picking the older one leaves the newer deleted.
        let older = store.deletedItems.mostRecentFirst.last!
        store.undoDelete(id: older.id)

        XCTAssertEqual(store.entries.map(\.name), ["a"])
        XCTAssertEqual(store.deletedItems.entries.count, 1)
    }

    func testADeleteThatRemovedNothingIsNotOffered() {
        let store = makeStore()
        store.upsert(SessionEntry(name: "web-01", folder: "", hostname: "w.example.com"))

        store.delete(ids: [UUID()])

        XCTAssertTrue(store.deletedItems.isEmpty, "nothing was deleted, so there is nothing to undo")
        XCTAssertEqual(store.entries.count, 1)
    }

    /// A second window, or a re-import, can put the row back first. Undo must
    /// not then add a duplicate.
    func testUndoDoesNotDuplicateSomethingAlreadyBack() {
        let store = makeStore()
        store.upsert(SessionEntry(name: "web-01", folder: "", hostname: "w.example.com"))
        let entry = store.entries[0]
        store.delete(entry)
        store.upsert(entry)

        store.undoLastDelete()

        XCTAssertEqual(store.entries.count, 1)
    }

    func testRestoredItemsPersist() {
        let store = makeStore()
        store.upsert(SessionEntry(name: "web-01", folder: "prod", hostname: "w.example.com"))
        store.delete(store.entries[0])
        store.undoLastDelete()

        let reloaded = SessionStore(fileURL: tempURL, seedsFromSSHConfig: false)
        XCTAssertEqual(reloaded.entries.map(\.name), ["web-01"])
        XCTAssertEqual(reloaded.entries.first?.folder, "prod")
    }

    func testUndoingWithNothingDeletedIsANoOp() {
        let store = makeStore()
        XCTAssertNil(store.undoLastDelete())
    }
}
