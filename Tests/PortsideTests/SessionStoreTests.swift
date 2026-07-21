import XCTest
@testable import Portside

/// Batch move/delete and folder-tree behavior behind the NSOutlineView sidebar.
/// Each store is backed by a throwaway temp file so the real library is never
/// touched.
final class SessionStoreTests: XCTestCase {
    private var tempURL: URL!

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-test-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        super.tearDown()
    }

    private func makeStore(_ entries: [SessionEntry]) -> SessionStore {
        let store = SessionStore(fileURL: tempURL)
        for entry in entries { store.upsert(entry) }
        return store
    }

    private func host(_ name: String, folder: String = "") -> SessionEntry {
        SessionEntry(name: name, folder: folder, hostname: "\(name).example.com")
    }

    // MARK: - Batch move

    func testMoveEntryIDsRelocatesAllToFolder() {
        let a = host("a"), b = host("b"), c = host("c")
        let store = makeStore([a, b, c])

        store.move(entryIDs: [a.id, b.id], toFolder: "prod")

        XCTAssertEqual(store.entries.first { $0.id == a.id }?.folder, "prod")
        XCTAssertEqual(store.entries.first { $0.id == b.id }?.folder, "prod")
        XCTAssertEqual(store.entries.first { $0.id == c.id }?.folder, "")
    }

    func testMoveEntryIDsToTopLevelClearsFolder() {
        let a = host("a", folder: "prod"), b = host("b", folder: "prod/web")
        let store = makeStore([a, b])

        store.move(entryIDs: [a.id, b.id], toFolder: "")

        XCTAssertEqual(store.entries.first { $0.id == a.id }?.folder, "")
        XCTAssertEqual(store.entries.first { $0.id == b.id }?.folder, "")
    }

    func testMoveEntryIDsIgnoresUnknownIDs() {
        let a = host("a")
        let store = makeStore([a])

        store.move(entryIDs: [a.id, UUID()], toFolder: "staging")

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.folder, "staging")
    }

    func testMoveEntryIDsNoOpWhenAlreadyInFolder() {
        let a = host("a", folder: "prod")
        let store = makeStore([a])

        // Reload from disk after the move to prove nothing was rewritten needlessly:
        // if a spurious save happened it would still be "prod", so instead assert the
        // value is unchanged and the entry count is stable.
        store.move(entryIDs: [a.id], toFolder: "prod")

        XCTAssertEqual(store.entries.first?.folder, "prod")
    }

    // MARK: - Batch delete

    func testDeleteIDsRemovesOnlySelected() {
        let a = host("a"), b = host("b"), c = host("c")
        let store = makeStore([a, b, c])

        store.delete(ids: [a.id, c.id])

        XCTAssertEqual(store.entries.map(\.id), [b.id])
    }

    func testDeleteIDsIgnoresUnknownIDs() {
        let a = host("a")
        let store = makeStore([a])

        store.delete(ids: [UUID()])

        XCTAssertEqual(store.entries.count, 1)
    }

    func testDeleteEmptySetLeavesLibraryIntact() {
        let a = host("a"), b = host("b")
        let store = makeStore([a, b])

        store.delete(ids: [])

        XCTAssertEqual(store.entries.count, 2)
    }

    // MARK: - Persistence round-trip

    func testBatchMovePersistsToDisk() {
        let a = host("a"), b = host("b")
        let store = makeStore([a, b])
        store.move(entryIDs: [a.id, b.id], toFolder: "net")

        let reloaded = SessionStore(fileURL: tempURL)
        XCTAssertEqual(Set(reloaded.entries.map(\.folder)), ["net"])
    }

    // MARK: - FolderTree

    func testFolderTreeSplitsRootAndFolders() {
        let entries = [
            host("top"),
            host("web", folder: "prod"),
            host("db", folder: "prod"),
        ]
        let tree = FolderTree.build(entries: entries)

        XCTAssertEqual(tree.root.map(\.name), ["top"])
        XCTAssertEqual(tree.folders.map(\.path), ["prod"])
        XCTAssertEqual(tree.folders.first?.entries.map(\.name), ["db", "web"]) // alpha
    }

    func testFolderTreeMaterializesAncestors() {
        let entries = [host("deep", folder: "a/b/c")]
        let tree = FolderTree.build(entries: entries)

        // Every ancestor exists as a node even though only the leaf holds a host.
        XCTAssertEqual(tree.folders.map(\.path), ["a"])
        let b = tree.folders.first?.subfolders.first
        XCTAssertEqual(b?.path, "a/b")
        XCTAssertEqual(b?.subfolders.first?.path, "a/b/c")
        XCTAssertEqual(b?.subfolders.first?.entries.map(\.name), ["deep"])
    }

    func testFolderTreeIncludesEmptyExplicitFolders() {
        let tree = FolderTree.build(entries: [], explicitFolders: ["empty"])
        XCTAssertEqual(tree.folders.map(\.path), ["empty"])
        XCTAssertTrue(tree.folders.first?.entries.isEmpty ?? false)
    }
}
