import XCTest
@testable import Portside

/// Help ▸ Report an Issue fills the bug form from `Diagnostics`. The form
/// warns people not to paste their library, so the one thing this must never
/// do is put a hostname, user, folder or repository into a URL the browser
/// opens and the person may submit.
final class DiagnosticsTests: XCTestCase {
    private func library() -> (entries: [SessionEntry], sources: [InventorySource]) {
        var web = SessionEntry(name: "web-prod-secret", folder: "customers/acme-secret", hostname: "db7.acme-secret.example")
        web.user = "alice-secret"
        web.identityFile = "/Users/alice-secret/.ssh/id_secret"
        var box = SessionEntry(name: "box-secret", hostname: "", kind: .container)
        box.container = ContainerTarget(engine: .docker, name: "payroll-secret", shell: "sh")
        let pod = SessionEntry(name: "pod-secret", folder: "customers", hostname: "", kind: .kubernetes)
        var off = InventorySource(name: "Team-secret", remote: "git@github.com:acme-secret/inventory.git")
        off.isEnabled = false
        return ([web, box, pod], [InventorySource(name: "Home-secret", remote: "/Users/alice-secret/repo"), off])
    }

    private func diagnostics(agent: Bool = true) -> Diagnostics {
        let (entries, sources) = library()
        var terminal = TerminalSettings()
        terminal.injectShellIntegration = true
        var settings = AgentController.Settings()
        settings.enabled = agent
        settings.allowInput = true
        settings.dontAskAllowed = true
        return .current(entries: entries, groups: 2, macros: 5, inventorySources: sources,
                        terminal: terminal, logging: LoggingSettings(), agent: settings)
    }

    func testNothingIdentifyingReachesTheReport() {
        let d = diagnostics()
        let everything = d.text + "\n" + d.issueURL().absoluteString.removingPercentEncoding!
        XCTAssertFalse(everything.lowercased().contains("secret"), everything)
        XCTAssertFalse(everything.contains("acme"), everything)
        XCTAssertFalse(everything.contains("/Users"), everything)
    }

    func testTheLibraryIsDescribedByCounts() {
        let d = diagnostics()
        XCTAssertEqual(d.libraryLine,
                       "3 entries (1 SSH Host, 1 Container, 1 Kubernetes), 2 folders, 2 groups, 5 macros, "
                       + "2 shared inventories (1 on)")
    }

    /// An empty folder and one kept only by a group are folders the sidebar
    /// shows, so they count.
    func testFoldersWithoutEntriesCount() {
        let d = Diagnostics.current(entries: [], otherFolders: ["empty", "ops/groups-only"], groups: 1, macros: 0,
                                    inventorySources: [], terminal: TerminalSettings(), logging: LoggingSettings(),
                                    agent: AgentController.Settings())
        XCTAssertTrue(d.libraryLine.contains("3 folders"), d.libraryLine)
    }

    func testSwitchesThatChangeBehaviourAreListed() {
        XCTAssertEqual(diagnostics().settingsLines, [
            "Directory tracking on connect: on",
            "Session logging: off",
            "Metal renderer: off",
            "Agent Access: on",
            "Agent typing: on",
            "Agent editing: off",
            "Don't Ask: allowed, off",
            "Approved programs: 0",
        ])
        XCTAssertEqual(diagnostics(agent: false).settingsLines.last, "Agent Access: off",
                       "agent details only when Agent Access is on")
    }

    func testTheIssueURLOpensTheBugFormFilledIn() throws {
        let d = diagnostics()
        let items = try XCTUnwrap(URLComponents(url: d.issueURL(), resolvingAgainstBaseURL: false)?.queryItems)
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(values["template"], "bug_report.yml")
        XCTAssertEqual(values["version"], d.versionLine)
        XCTAssertEqual(values["macos"], d.macOSLine)
        XCTAssertEqual(values["library"], d.libraryLine)
        XCTAssertEqual(values["settings"], d.settingsLines.joined(separator: "\n"))
    }

    /// GitHub fills only fields whose id matches a parameter, silently. A
    /// renamed field in the template would leave the form blank.
    func testEveryParameterIsAFieldInTheBugTemplate() throws {
        let template = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".github/ISSUE_TEMPLATE/bug_report.yml")
        let yaml = try String(contentsOf: template, encoding: .utf8)
        let ids = Set(yaml.components(separatedBy: "\n").compactMap { line -> String? in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("id: ") ? String(t.dropFirst(4)) : nil
        })
        let items = URLComponents(url: diagnostics().issueURL(), resolvingAgainstBaseURL: false)?.queryItems ?? []
        for item in items where item.name != "template" {
            XCTAssertTrue(ids.contains(item.name), "bug_report.yml has no field \(item.name); it has \(ids.sorted())")
        }
    }
}
