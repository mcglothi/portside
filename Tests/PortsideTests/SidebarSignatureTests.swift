import XCTest
@testable import Portside

/// The fingerprint that decides whether the sidebar redraws.
///
/// This is a cache key with teeth: a field missing from it doesn't fail loudly,
/// it just leaves the outline showing the old state until some unrelated edit
/// forces a rebuild. That reads as a move that silently didn't take — the
/// library on disk correct, the sidebar wrong, and nothing to point at.
final class SidebarSignatureTests: XCTestCase {

    private func host(_ name: String, folder: String = "") -> SessionEntry {
        SessionEntry(name: name, folder: folder, hostname: "\(name).example.com")
    }

    private func group(_ name: String, folder: String = "") -> SessionGroup {
        SessionGroup(name: name, folder: folder, layout: WorkspaceSnapshot.TabSnapshot(
            root: .leaf(WorkspaceSnapshot.Leaf(kind: .localShell, includedInMultiExec: true))))
    }

    private func tree(_ entries: [SessionEntry],
                      folders: [String] = [],
                      groups: [SessionGroup] = []) -> SidebarTree {
        FolderTree.build(entries: entries, explicitFolders: folders, groups: groups)
    }

    /// The reported bug. Dragging hosts from `prod` into the empty `prod/web`
    /// produced a byte-identical fingerprint, because the flattened walk visits
    /// subfolders before their parent's own rows — so the entries arrived in the
    /// child at exactly the position they had occupied in the parent.
    func testMovingHostsIntoAnEmptySubfolderChangesTheSignature() {
        var web1 = host("web-01", folder: "prod")
        var web2 = host("web-02", folder: "prod")
        let before = tree([web1, web2], folders: ["prod", "prod/web"])

        web1.folder = "prod/web"
        web2.folder = "prod/web"
        let after = tree([web1, web2], folders: ["prod", "prod/web"])

        XCTAssertNotEqual(before.signature, after.signature)
    }

    func testMovingAHostToTheTopLevelChangesTheSignature() {
        var entry = host("web-01", folder: "prod")
        let before = tree([entry], folders: ["prod"])
        entry.folder = ""
        XCTAssertNotEqual(before.signature, tree([entry], folders: ["prod"]).signature)
    }

    /// Same hazard for groups, which can be filed since 0.21.
    func testMovingAGroupIntoAnEmptySubfolderChangesTheSignature() {
        var g = group("Splunk", folder: "prod")
        let before = tree([], folders: ["prod", "prod/web"], groups: [g])
        g.folder = "prod/web"
        let after = tree([], folders: ["prod", "prod/web"], groups: [g])

        XCTAssertNotEqual(before.signature, after.signature)
    }

    func testMovingBetweenTwoSiblingFoldersChangesTheSignature() {
        var entry = host("web-01", folder: "lab")
        let before = tree([entry], folders: ["lab", "staging"])
        entry.folder = "staging"
        XCTAssertNotEqual(before.signature, tree([entry], folders: ["lab", "staging"]).signature)
    }

    // MARK: - The other direction: it must not churn

    /// The fingerprint exists to *avoid* rebuilds, so an unchanged tree has to
    /// produce an unchanged string — otherwise the outline rebuilds on every
    /// redraw and selection and scroll position go with it.
    func testAnUnchangedTreeKeepsTheSameSignature() {
        let entries = [host("web-01", folder: "prod"), host("db-01")]
        let groups = [group("Splunk", folder: "prod")]
        XCTAssertEqual(tree(entries, folders: ["prod"], groups: groups).signature,
                       tree(entries, folders: ["prod"], groups: groups).signature)
    }

    // MARK: - The fields that decide how a row draws

    func testRenamingAHostChangesTheSignature() {
        var entry = host("web-01")
        let before = tree([entry])
        entry.name = "web-99"
        XCTAssertNotEqual(before.signature, tree([entry]).signature)
    }

    func testFavouritingChangesTheSignature() {
        var entry = host("web-01")
        let before = tree([entry])
        entry.isFavorite = true
        XCTAssertNotEqual(before.signature, tree([entry]).signature)
    }

    func testFavouritingAGroupChangesTheSignature() {
        var g = group("Splunk")
        let before = tree([], groups: [g])
        g.isFavorite = true
        XCTAssertNotEqual(before.signature, tree([], groups: [g]).signature)
    }

    /// The transport badge is drawn from neither the name nor the subtitle, so
    /// flipping a host to mosh changed the row and nothing the fingerprint saw.
    func testSwitchingAHostToMoshChangesTheSignature() {
        var entry = host("web-01")
        let before = tree([entry])
        entry.preferMosh = true
        XCTAssertNotEqual(before.signature, tree([entry]).signature)
    }

    func testChangingTheSessionKindChangesTheSignature() {
        var entry = host("device-01")
        let before = tree([entry])
        entry.kind = .telnet
        XCTAssertNotEqual(before.signature, tree([entry]).signature,
                          "an unencrypted badge appearing is a visible change")
    }

    func testAddingAnEmptyFolderChangesTheSignature() {
        let entries = [host("web-01")]
        XCTAssertNotEqual(tree(entries).signature,
                          tree(entries, folders: ["lab"]).signature)
    }

    func testDeletingOneOfTwoHostsChangesTheSignature() {
        let a = host("web-01"), b = host("web-02")
        XCTAssertNotEqual(tree([a, b]).signature, tree([a]).signature)
    }
}
