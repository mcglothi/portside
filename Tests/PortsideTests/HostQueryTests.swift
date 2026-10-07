import XCTest
@testable import Portside

final class HostQueryTests: XCTestCase {
    private func host(_ name: String, folder: String = "", env: HostEnvironment = .none,
                      kind: SessionKind = .host) -> SessionEntry {
        var e = SessionEntry(name: name, folder: folder, hostname: "\(name).example.com")
        e.environment = env
        e.kind = kind
        return e
    }

    func testPlainTermsAllMustMatch() {
        let q = HostQuery("web prod")
        XCTAssertTrue(q.matches(host("web01", folder: "prod")))
        XCTAssertFalse(q.matches(host("web01", folder: "lab")))
    }

    func testFieldTerms() {
        let prodWeb = host("web01", env: .prod)
        XCTAssertTrue(HostQuery("env:prod").matches(prodWeb))
        XCTAssertTrue(HostQuery("ENV:Pr").matches(prodWeb), "enum fields match by prefix, any case")
        XCTAssertFalse(HostQuery("env:dev").matches(prodWeb))
        XCTAssertTrue(HostQuery("kind:k8s").matches(host("api", kind: .kubernetes)))
        XCTAssertTrue(HostQuery("folder:lab").matches(host("x", folder: "home/lab")))
    }

    func testMoshAndSshKindsSplitHosts() {
        var mosh = host("roamer")
        mosh.preferMosh = true
        XCTAssertTrue(HostQuery("kind:mosh").matches(mosh))
        XCTAssertFalse(HostQuery("kind:ssh").matches(mosh))
        XCTAssertTrue(HostQuery("kind:host").matches(mosh))
    }

    func testNegation() {
        XCTAssertFalse(HostQuery("-env:prod").matches(host("a", env: .prod)))
        XCTAssertTrue(HostQuery("-env:prod").matches(host("a", env: .dev)))
        XCTAssertFalse(HostQuery("-web").matches(host("web01")))
    }

    func testProfileLookup() {
        let id = UUID()
        var e = host("box")
        e.credentialProfileID = id
        XCTAssertTrue(HostQuery("profile:ansi").matches(e, profileNames: [id: "Ansible"]))
        XCTAssertFalse(HostQuery("profile:none").matches(e, profileNames: [id: "Ansible"]))
        XCTAssertTrue(HostQuery("profile:none").matches(host("bare")))
    }

    func testFlags() {
        var e = host("a")
        e.isFavorite = true
        XCTAssertTrue(HostQuery("is:fav").matches(e))
        XCTAssertFalse(HostQuery("is:protected").matches(e))
    }

    /// Half-typed fields and colon-bearing text must not blank the list.
    func testIncompleteAndUnknownKeysFallBackSafely() {
        XCTAssertTrue(HostQuery("env:").isEmpty)
        XCTAssertEqual(HostQuery("fe80::1").terms, [.init(key: nil, value: "fe80::1")])
        XCTAssertEqual(HostQuery("-").terms, [.init(key: nil, value: "-")])
    }

    func testGroupsLackHostOnlyFields() {
        let group = SessionGroup(name: "Splunk", folder: "ops", layout: WorkspaceSnapshot.TabSnapshot(
            root: .leaf(WorkspaceSnapshot.Leaf(kind: .localShell, includedInMultiExec: true))))
        XCTAssertFalse(HostQuery("env:prod").matches(group))
        XCTAssertTrue(HostQuery("-env:prod").matches(group))
        XCTAssertTrue(HostQuery("folder:ops splunk").matches(group))
    }

    func testFolderPathOnlyAnswersPathTerms() {
        XCTAssertTrue(HostQuery("lab").matches(folderPath: "home/lab"))
        XCTAssertTrue(HostQuery("folder:lab").matches(folderPath: "home/lab"))
        XCTAssertFalse(HostQuery("lab env:prod").matches(folderPath: "home/lab"))
    }

    func testRegexTerms() {
        XCTAssertTrue(HostQuery("/^db-\\d+/").matches(host("DB-12")), "case-insensitive")
        XCTAssertFalse(HostQuery("/^db-\\d+/").matches(host("web-db-1")))
        XCTAssertTrue(HostQuery("folder:/lab|prod/").matches(host("x", folder: "home/prod")))
        XCTAssertFalse(HostQuery("-folder:/lab|prod/").matches(host("x", folder: "home/lab")))
        XCTAssertTrue(HostQuery("env:/^(prod|staging)$/").matches(host("x", env: .staging)))
        XCTAssertFalse(HostQuery("env:/^prod$/").matches(host("x", env: .staging)))
        XCTAssertTrue(HostQuery("kind:/k8s|mosh/").matches(host("api", kind: .kubernetes)))
        XCTAssertTrue(HostQuery("/lab/").matches(folderPath: "home/lab"))
    }

    /// A broken pattern is reported and ignored — it must not blank the list.
    func testInvalidRegexIsReportedNotApplied() {
        let q = HostQuery("web /[unclosed/")
        XCTAssertEqual(q.invalidPatterns, ["/[unclosed/"])
        XCTAssertEqual(q.terms.count, 1)
        XCTAssertTrue(q.matches(host("web01")))
        XCTAssertNil(HostQuery("//").terms.first?.regex, "// stays plain text")
        XCTAssertNil(HostQuery("/").terms.first?.regex)
    }

    func testCompletionsFinishTheTermBeingTyped() {
        XCTAssertEqual(HostQuery.completions(for: "web env:p", folders: [], profiles: []), ["web env:prod", "web env:personal"])
        XCTAssertEqual(HostQuery.completions(for: "-is:", folders: [], profiles: []), ["-is:fav", "-is:protected"])
        XCTAssertEqual(HostQuery.completions(for: "folder:", folders: ["home/lab", "my lab"], profiles: []),
                       ["folder:home/lab"], "values with spaces can't round-trip through the parser")
        XCTAssertEqual(HostQuery.completions(for: "env:prod", folders: [], profiles: []), [], "already complete")
        XCTAssertEqual(HostQuery.completions(for: "env:p ", folders: [], profiles: []), [], "term finished")
        XCTAssertEqual(HostQuery.completions(for: "web", folders: [], profiles: []), [])
        XCTAssertEqual(HostQuery.completions(for: "env:/p", folders: [], profiles: []), [], "no completion inside a regex")
    }
}
