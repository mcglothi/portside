import AppKit
import XCTest
@testable import Portside

/// "Expand All in <folder>" has to open the folder's *whole* branch, not just
/// its immediate children — on a deeply foldered inventory (prod/web/api/…)
/// expanding one level at a time is no better than clicking the triangles.
///
/// This rests on `NSOutlineView.expandItem(_:expandChildren:)` recursing, which
/// is worth pinning down rather than assuming: getting it wrong is silent, and
/// only shows up on a nested library.
final class FolderExpansionTests: XCTestCase {

    /// Minimal stand-in for the sidebar's node tree.
    private final class Node: NSObject {
        let name: String
        let children: [Node]
        init(_ name: String, _ children: [Node] = []) {
            self.name = name
            self.children = children
        }
    }

    private final class Source: NSObject, NSOutlineViewDataSource {
        let roots: [Node]
        init(roots: [Node]) { self.roots = roots }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? Node)?.children.count ?? roots.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            (item as? Node)?.children[index] ?? roots[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            !((item as? Node)?.children.isEmpty ?? true)
        }
    }

    @MainActor
    func testExpandAllOnAParentOpensEveryNestedSubfolder() {
        // prod > web > api > (leaf), plus a sibling branch.
        let api = Node("api", [Node("leaf")])
        let web = Node("web", [api])
        let db = Node("db", [Node("primary")])
        let prod = Node("prod", [web, db])
        let staging = Node("staging", [Node("web")])

        let source = Source(roots: [prod, staging])
        let outline = NSOutlineView()
        let column = NSTableColumn(identifier: .init("c"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.dataSource = source
        outline.reloadData()

        outline.expandItem(prod, expandChildren: true)

        XCTAssertTrue(outline.isItemExpanded(prod), "the folder itself")
        XCTAssertTrue(outline.isItemExpanded(web), "a direct subfolder")
        XCTAssertTrue(outline.isItemExpanded(db), "a sibling subfolder")
        XCTAssertTrue(outline.isItemExpanded(api), "a grandchild must expand too")
        XCTAssertFalse(
            outline.isItemExpanded(staging),
            "an unrelated top-level folder must be left alone — this is scoped, not global"
        )
    }

    @MainActor
    func testCollapseAllOnAParentClosesEveryNestedSubfolder() {
        let api = Node("api", [Node("leaf")])
        let web = Node("web", [api])
        let prod = Node("prod", [web])

        let source = Source(roots: [prod])
        let outline = NSOutlineView()
        let column = NSTableColumn(identifier: .init("c"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.dataSource = source
        outline.reloadData()

        outline.expandItem(prod, expandChildren: true)
        outline.collapseItem(prod, collapseChildren: true)

        XCTAssertFalse(outline.isItemExpanded(prod))
        XCTAssertFalse(outline.isItemExpanded(web))
        XCTAssertFalse(
            outline.isItemExpanded(api),
            "a re-expand must not spring the whole branch back open"
        )
    }

    /// The tree the sidebar actually feeds the outline view has to nest in the
    /// first place, or there'd be nothing for the recursion to walk.
    func testFolderTreeNestsDeepPaths() {
        let entry = SessionEntry(name: "api1", folder: "prod/web/api", hostname: "api1.example.com")
        let tree = FolderTree.build(entries: [entry], explicitFolders: [])

        let prod = tree.folders.first { $0.path == "prod" }
        XCTAssertNotNil(prod)
        let web = prod?.subfolders.first { $0.path == "prod/web" }
        XCTAssertNotNil(web, "prod/web should nest under prod")
        let api = web?.subfolders.first { $0.path == "prod/web/api" }
        XCTAssertNotNil(api, "prod/web/api should nest under prod/web")
        XCTAssertEqual(api?.entries.map(\.name), ["api1"])
    }
}
