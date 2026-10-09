import XCTest
@testable import Portside

/// Agents managing shared inventories and the user's own hosts: what they can
/// do with the editing switch on, and the lines they can't cross even then.
@MainActor
final class AgentInventoryTests: XCTestCase {
    private var root: URL!
    private var bare: URL { root.appendingPathComponent("team.git") }
    private var keepAlive: [AnyObject] = []
    private let claude = AgentClient(pid: 1, name: "claude", path: "")

    override func setUp() async throws {
        root = URL(fileURLWithPath: "/tmp/pai-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try InventoryGit.run(["init", "--quiet", "--bare", "--initial-branch=main", bare.path], in: nil)
    }

    override func tearDown() async throws {
        keepAlive = []
        try? FileManager.default.removeItem(at: root)
    }

    private func controller(_ entries: [SessionEntry] = [], edit: Bool = true)
        -> (AgentController, SessionStore) {
        let store = SessionStore(fileURL: root.appendingPathComponent("lib/portside.json"))
        entries.forEach(store.upsert)
        let sessions = SessionManager()
        let agent = AgentController()
        agent.promptTimeout = 5
        agent.approvalArmingDelay = 0
        agent.configure(store: store, sessions: sessions)
        agent.setEnabled(true)
        if edit { agent.setAllowEdit(true) }
        keepAlive = [store, sessions]
        return (agent, store)
    }

    private func host(_ name: String, folder: String = "team", protected: Bool = false) -> SessionEntry {
        var e = SessionEntry(name: name, folder: folder, hostname: "\(name).example.com")
        e.isProtected = protected
        return e
    }

    /// Runs a request, answering each prompt it raises in turn; asserts the
    /// number of prompts matched.
    private func run(_ agent: AgentController, _ method: String, _ params: AgentProtocol.Params = .init(),
                     answering choices: [Int?] = [], file: StaticString = #filePath, line: UInt = #line)
        async -> AgentProtocol.Response {
        let task = Task { await agent.handle(.init(method: method, params: params), from: claude) }
        for choice in choices {
            for _ in 0..<400 where agent.prompt == nil { try? await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertNotNil(agent.prompt, "expected a prompt", file: file, line: line)
            agent.answer(choice)
        }
        return await task.value
    }

    // MARK: - Editing hosts

    func testEditingIsOffUntilItsSwitchIsOn() async {
        let (agent, store) = controller(edit: false)
        let r = await run(agent, "host-add", .init(name: "web9", hostname: "web9.example.com"))
        XCTAssertEqual(r.error?.code, "denied")
        XCTAssertNil(agent.prompt)
        XCTAssertTrue(store.entries.isEmpty)
    }

    /// The first edit asks (letting the program in, then the edit itself);
    /// "Allow Edits This Session" means the next one doesn't.
    func testAddingHostsAsksOnceASession() async {
        let (agent, store) = controller()
        let first = await run(agent, "host-add", .init(name: "web1", folder: "team", hostname: "web1.example.com",
                                                       user: "deploy", port: 2222, environment: "prod"),
                              answering: [0, 0])
        XCTAssertNil(first.error, "\(String(describing: first.error))")
        let second = await run(agent, "host-add", .init(name: "web2", folder: "team", hostname: "web2.example.com"))
        XCTAssertNil(second.error)
        XCTAssertEqual(store.entries.map(\.name).sorted(), ["web1", "web2"])
        let web1 = store.entries.first { $0.name == "web1" }
        XCTAssertEqual(web1?.port, 2222)
        XCTAssertEqual(web1?.environment, .prod)
    }

    func testOptionShapedValuesAreRefused() async {
        let (agent, store) = controller()
        _ = await run(agent, "host-add", .init(name: "ok", hostname: "ok.example.com"), answering: [0, 0])
        for bad in [AgentProtocol.Params(name: "x", hostname: "-oProxyCommand=open"),
                    AgentProtocol.Params(name: "y", hostname: "y.example.com", user: "-l"),
                    AgentProtocol.Params(name: "z", alias: "a;b")] {
            let r = await run(agent, "host-add", bad)
            XCTAssertEqual(r.error?.code, "bad_request", "\(bad)")
        }
        XCTAssertEqual(store.entries.map(\.name), ["ok"])
    }

    /// #26: an agent can add a Kubernetes entry pointed at a workload, and a
    /// container entry, not only SSH hosts.
    func testAddingKubernetesAndContainerEntries() async throws {
        let (agent, store) = controller()
        let k = await run(agent, "host-add",
                          .init(name: "web (nkp)", folder: "k8s", kind: "kubernetes",
                                kubernetes: .init(context: "nkp-prod", namespace: "shop", target: "deploy/web",
                                                  container: "app", kubeconfig: "~/.kube/nkp-prod.conf", cli: "kubectl")),
                          answering: [0, 0])
        XCTAssertNil(k.error, "\(String(describing: k.error))")
        let entry = try XCTUnwrap(store.entries.first { $0.name == "web (nkp)" })
        XCTAssertEqual(entry.kind, .kubernetes)
        XCTAssertEqual(entry.kubernetes?.pod, "deploy/web")
        XCTAssertTrue(entry.postConnectCommand?.contains("exec -it deploy/web --container=app -- sh") == true,
                      entry.postConnectCommand ?? "nil")

        let c = await run(agent, "host-add", .init(name: "redis", kind: "container",
                                                   container: .init(engine: "podman", target: "redis-1")))
        XCTAssertNil(c.error, "\(String(describing: c.error))")
        XCTAssertEqual(store.entries.first { $0.name == "redis" }?.postConnectCommand, "podman exec -it redis-1 sh")
    }

    func testKubernetesEntriesAreCheckedLikeHosts() async {
        let (agent, store) = controller()
        _ = await run(agent, "host-add", .init(name: "ok", hostname: "ok.example.com"), answering: [0, 0])
        let bad: [AgentProtocol.Params] = [
            .init(name: "a", kind: "kubernetes"),                                             // no target
            .init(name: "b", kind: "kubernetes", kubernetes: .init(target: "--raw=/")),       // option-shaped
            .init(name: "c", kind: "kubernetes", kubernetes: .init(target: "web", cli: "helm")),
            .init(name: "d", kind: "kubernetes", kubernetes: .init(context: "x\u{1B}]0;y", target: "web")),
            .init(name: "e", hostname: "e.example.com", kubernetes: .init(target: "web")),    // wrong kind
            .init(name: "f", kind: "serial"),
            .init(name: "g", kind: "container", container: .init(engine: "lxc", target: "x")),
        ]
        for params in bad {
            let r = await run(agent, "host-add", params)
            XCTAssertEqual(r.error?.code, "bad_request", "\(params)")
        }
        XCTAssertEqual(store.entries.map(\.name), ["ok"])
    }

    /// An update has to leave an entry that can still connect — the same
    /// bar as adding one.
    func testUpdatesCantLeaveAnEntryThatCantConnect() async {
        var pod = SessionEntry(name: "web (k8s)", folder: "team", hostname: "", kind: .kubernetes)
        var target = KubernetesTarget()
        target.pod = "deploy/web"
        pod.kubernetes = target
        let (agent, store) = controller([host("web1"), pod])
        let cleared = await run(agent, "host-update", .init(ids: [store.entries[0].id.uuidString], hostname: ""),
                                answering: [0])
        XCTAssertEqual(cleared.error?.code, "bad_request", "\(String(describing: cleared.error))")
        XCTAssertEqual(store.entries.first { $0.name == "web1" }?.hostname, "web1.example.com")

        var params = AgentProtocol.Params(ids: [pod.id.uuidString])
        params.kubernetes = .init(target: "  ")
        let noTarget = await run(agent, "host-update", params)
        XCTAssertEqual(noTarget.error?.code, "bad_request")
        XCTAssertEqual(store.entries.first { $0.name == "web (k8s)" }?.kubernetes?.pod, "deploy/web")
    }

    /// `portside host update redis --target redis-2` sends the target in a
    /// `kubernetes` object, since the CLI can't tell; on a container entry
    /// it's the container's.
    func testATargetOnlyUpdateToAContainerChangesTheContainer() async {
        var box = SessionEntry(name: "redis", folder: "team", hostname: "", kind: .container)
        box.container = ContainerTarget(engine: .docker, name: "redis-1")
        let (agent, store) = controller([box])
        var params = AgentProtocol.Params(ids: [box.id.uuidString])
        params.kubernetes = .init(target: "redis-2", shell: "bash")
        let r = await run(agent, "host-update", params, answering: [0, 0])
        XCTAssertNil(r.error, "\(String(describing: r.error))")
        XCTAssertEqual(store.entries.first?.container?.name, "redis-2")
        XCTAssertEqual(store.entries.first?.container?.shell, "bash")
    }

    /// Approving editing never asked about typing, so it doesn't grant it —
    /// even though `edit` ranks above `input` — when typing is switched on.
    func testAnEditApprovalDoesntLetAProgramType() async {
        let (agent, _) = controller()
        let added = await run(agent, "host-add", .init(name: "web1", folder: "team", hostname: "web1.example.com"),
                              answering: [0, 0])   // Allow Editing Too, then the edit
        XCTAssertNil(added.error)
        XCTAssertEqual(agent.settings.approvals.first?.tier, .edit)
        agent.setAllowInput(true)
        let task = Task { await agent.handle(.init(method: "screen", params: .init(pane: "current")), from: claude) }
        for _ in 0..<300 where agent.prompt == nil { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(agent.prompt, "typing was assumed from an edit approval")
        agent.answer(agent.prompt?.refusal)
        _ = await task.value
    }

    func testProtectionCanBeAddedNeverRemovedAndAsksEveryTime() async {
        let (agent, store) = controller([host("db1", protected: true)])
        // Even after "this session", a protected host asks again.
        _ = await run(agent, "host-add", .init(name: "tmp", hostname: "tmp.example.com"), answering: [0, 0])
        let lift = await run(agent, "host-update", .init(name: "db1", protected: false))
        XCTAssertEqual(lift.error?.code, "denied")
        let change = await run(agent, "host-update", .init(name: "db1", port: 5433), answering: [0])
        XCTAssertNil(change.error)
        XCTAssertEqual(store.entries.first { $0.name == "db1" }?.port, 5433)
        XCTAssertTrue(store.entries.first { $0.name == "db1" }?.isProtected == true)
    }

    func testRemovalAlwaysAsksAndCanBeUndone() async {
        let (agent, store) = controller([host("a"), host("b")])
        _ = await run(agent, "host-add", .init(name: "c", hostname: "c.example.com"), answering: [0, 0])
        let declined = await run(agent, "host-remove", .init(ids: ["a"]), answering: [1])
        XCTAssertEqual(declined.error?.code, "declined")
        let r = await run(agent, "host-remove", .init(ids: ["a", "b"]), answering: [0])
        XCTAssertNil(r.error)
        XCTAssertEqual(store.entries.map(\.name), ["c"])
        XCTAssertNotNil(store.undoLastDelete())
        XCTAssertEqual(Set(store.entries.map(\.name)), ["a", "b", "c"])
    }

    func testTurningEditingOffTakesItBack() async {
        let (agent, _) = controller()
        _ = await run(agent, "host-add", .init(name: "a", hostname: "a.example.com"), answering: [0, 0])
        XCTAssertEqual(agent.settings.approvals.first?.tier, .edit)
        agent.setAllowEdit(false)
        XCTAssertEqual(agent.settings.approvals.first?.tier, .input)
        let r = await run(agent, "host-add", .init(name: "b", hostname: "b.example.com"))
        XCTAssertEqual(r.error?.code, "denied")
    }

    // MARK: - Shared inventories

    /// A source with `names` published, the store linked to it (creating it
    /// from the "team" folder).
    private func published(_ names: [String], _ store: SessionStore) async throws -> InventorySource {
        names.map { host($0) }.forEach(store.upsert)
        let src = InventorySource(name: "Team", remote: bare.path)
        guard case .success = await store.createSharedInventory(src, fromFolder: "team") else {
            XCTFail("couldn't create the inventory (does git have a user.name/user.email?)")
            throw NSError(domain: "AgentInventoryTests", code: 1)
        }
        return src
    }

    func testSharedHostsAreReadOnlyToAgents() async throws {
        let (agent, store) = controller()
        let src = try await published(["web1"], store)
        let shared = try XCTUnwrap(store.sharedEntries(inSource: src.id).first)
        _ = await run(agent, "status", answering: [0])  // let it in (read+open)
        let r = await run(agent, "host-update", .init(ids: [shared.id.uuidString], port: 1), answering: [0])
        XCTAssertEqual(r.error?.code, "denied")
        XCTAssertTrue(r.error?.message.contains("read-only") == true, r.error?.message ?? "")
    }

    func testSourcesAndPreviewDescribeThePublish() async throws {
        let (agent, store) = controller()
        _ = try await published(["web1", "web2"], store)
        var e = try XCTUnwrap(store.entries.first { $0.name == "web1" })
        e.user = "ops"
        store.upsert(e)

        let sources = await run(agent, "sources", answering: [1])  // read only is enough
        guard case .array(let rows)? = sources.result, case .object(let row)? = rows.first else {
            return XCTFail("\(String(describing: sources.error))")
        }
        XCTAssertEqual(row["linkedFolder"], .string("team"))
        XCTAssertEqual(row["hosts"], JSONValue(2))

        let preview = await run(agent, "publish-preview", .init(source: "Team"))
        guard case .object(let p)? = preview.result, case .array(let outgoing)? = p["outgoing"] else {
            return XCTFail("\(String(describing: preview.error))")
        }
        XCTAssertEqual(outgoing.count, 1)
        XCTAssertEqual(p["target"], .string("review branch off main"))
    }

    /// Under Don't Ask a review branch may go without a prompt — the pull
    /// request is still a person's call — but a push straight onto the
    /// team's branch always asks.
    func testDontAskSendsReviewBranchesButNeverDirectPushes() async throws {
        let (agent, store) = controller()
        let src = try await published(["web1"], store)
        agent.setDontAskAllowed(true)

        var e = try XCTUnwrap(store.entries.first { $0.name == "web1" })
        e.port = 2201
        store.upsert(e)
        let review = await run(agent, "publish", .init(source: "Team"))
        guard case .object(let r)? = review.result else { return XCTFail("\(String(describing: review.error))") }
        XCTAssertEqual(r["review"], .bool(true))
        XCTAssertNil(agent.prompt)

        store.setDirectPush(true, forSource: src.id)
        e.port = 2202
        store.upsert(e)
        let task = Task { await agent.handle(.init(method: "publish", params: .init(source: "Team")), from: claude) }
        for _ in 0..<400 where agent.prompt == nil { try? await Task.sleep(nanoseconds: 10_000_000) }
        let prompt = try XCTUnwrap(agent.prompt, "a direct push asked, Don't Ask notwithstanding")
        XCTAssertTrue(prompt.message.contains("Straight onto main"), prompt.message)
        agent.answer(prompt.refusal)
        let direct = await task.value
        XCTAssertEqual(direct.error?.code, "declined")
    }

    func testConflictsMustBeResolvedExplicitly() async throws {
        let (agent, store) = controller()
        let src = try await published(["web1"], store)
        store.setDirectPush(true, forSource: src.id)
        // A teammate changes web1 on main.
        let mate = root.appendingPathComponent("mate")
        _ = try InventoryGit.run(["clone", "--quiet", bare.path, mate.path], in: nil)
        let file = mate.appendingPathComponent("portside.json")
        var team = try SharedManifest.parseKeepingIDs(Data(contentsOf: file))
        team.entries[0].user = "theirs"
        try LibraryTransfer.encodeSessions(entries: team.entries, folders: [], credentialProfiles: []).write(to: file)
        _ = try InventoryGit.run(["-c", "user.name=M", "-c", "user.email=m@e", "-c", "commit.gpgsign=false",
                                  "commit", "--quiet", "-am", "theirs"], in: mate)
        _ = try InventoryGit.run(["push", "--quiet", "origin", "main"], in: mate)

        var mine = try XCTUnwrap(store.entries.first { $0.name == "web1" })
        mine.user = "mine"
        store.upsert(mine)

        // Only the program's first-use prompt: an unresolved conflict refuses
        // before any publish confirmation is shown.
        let unresolved = await run(agent, "publish", .init(source: "Team"), answering: [0])
        XCTAssertEqual(unresolved.error?.code, "bad_request")
        XCTAssertTrue(unresolved.error?.message.contains("web1") == true)
        // The preview names each conflict by id too: two conflicting hosts
        // with the same name can only be resolved that way.
        let preview = await run(agent, "publish-preview", .init(source: "Team"))
        guard case .object(let p)? = preview.result, case .array(let conflicts)? = p["conflicts"],
              case .object(let c)? = conflicts.first, case .string(let id)? = c["id"] else {
            return XCTFail("no conflict id in \(String(describing: preview.result)) \(String(describing: preview.error))")
        }
        XCTAssertNotNil(UUID(uuidString: id))
        let bad = await run(agent, "publish", .init(source: "Team", resolutions: ["web1": "both"]))
        XCTAssertEqual(bad.error?.code, "bad_request")
        let ok = await run(agent, "publish", .init(source: "Team", resolutions: ["web1": "mine"]), answering: [0])
        XCTAssertNil(ok.error, "\(String(describing: ok.error))")
        let main = try SharedManifest.parseKeepingIDs(Data(try InventoryGit.run(
            ["--git-dir", bare.path, "show", "main:portside.json"], in: nil).utf8))
        XCTAssertEqual(main.entries.first?.user, "mine")
    }
}
