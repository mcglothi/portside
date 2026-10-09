import XCTest
@testable import Portside

/// Agent Access: the socket, who's asking, and the rules that don't bend for
/// an agent. Prompts are answered here the way a person would, through
/// `AgentController.answer`, because that is the only place they can be.
@MainActor
final class AgentAccessTests: XCTestCase {
    private var root: URL!
    /// The controller holds these weakly, as the app's @StateObjects own them.
    private var keepAlive: [AnyObject] = []

    override func setUp() async throws {
        root = URL(fileURLWithPath: "/tmp/psat-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func host(_ name: String, protected: Bool = false, env: HostEnvironment = .none) -> SessionEntry {
        var e = SessionEntry(name: name, folder: "lab", hostname: "\(name).example.com")
        e.isProtected = protected
        e.environment = env
        return e
    }

    // MARK: - Policy

    func testConnectConfirmationNamesProtectedHostsAndTheCap() {
        let plain = (1...3).map { host("web\($0)") }
        XCTAssertNil(AgentPolicy.connectConfirmation(for: plain, cap: 20))
        let reason = AgentPolicy.connectConfirmation(for: plain + [host("db1", protected: true)], cap: 20)
        XCTAssertTrue(reason?.contains("db1") == true, reason ?? "")
        let many = (1...25).map { host("h\($0)") }
        XCTAssertTrue(AgentPolicy.connectConfirmation(for: many, cap: 20)?.contains("25 hosts") == true)
    }

    func testSelectionRefusesEverythingAndBadInput() {
        let entries = [host("web1", env: .prod), host("web2"), host("db1", env: .prod)]
        func select(_ p: AgentProtocol.Params) -> Result<[SessionEntry], AgentProtocol.Failure> {
            AgentPolicy.selectHosts(p, from: entries, profileNames: [:])
        }
        guard case .failure = select(.init(query: "  ")) else { return XCTFail("an empty query must not mean all") }
        guard case .failure = select(.init(query: "/[/")) else { return XCTFail("invalid regex must fail") }
        guard case .failure = select(.init(ids: ["not-a-uuid"])) else { return XCTFail() }
        guard case .failure = select(.init(ids: [UUID().uuidString])) else { return XCTFail("unknown id") }
        guard case .success(let prod) = select(.init(query: "env:prod")) else { return XCTFail() }
        XCTAssertEqual(prod.map(\.name), ["db1", "web1"])
    }

    func testLongLibraryPathsMoveTheSocketToTemp() {
        let short = AgentServer.socketPath(libraryDirectory: URL(fileURLWithPath: "/tmp/lib"))
        XCTAssertEqual(short, "/tmp/lib/agent.sock")
        let deep = URL(fileURLWithPath: "/tmp/" + String(repeating: "x", count: 120))
        let moved = AgentServer.socketPath(libraryDirectory: deep)
        XCTAssertLessThan(moved.utf8.count, 104)
        XCTAssertEqual(moved, AgentServer.socketPath(libraryDirectory: deep), "stable, so the CLI finds it")
    }

    // MARK: - Socket

    /// A real round trip: bind, mode, a request in, a response out, and the
    /// caller identified from its process.
    func testSocketRoundTripIsPrivateAndIdentifiesTheCaller() throws {
        let path = root.appendingPathComponent("agent.sock").path
        let server = AgentServer(socketPath: path) { request, client in
            AgentProtocol.Response(id: request.id, result: .object([
                "method": .string(request.method), "client": .string(client.name),
            ]))
        }
        try server.start()
        defer { server.stop() }

        var st = stat()
        XCTAssertEqual(lstat(path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600, "only this user may connect")

        let reply = try Self.roundTrip(path, #"{"id":7,"method":"status"}"#)
        XCTAssertEqual(reply["id"] as? Int, 7)
        let result = reply["result"] as? [String: Any]
        XCTAssertEqual(result?["method"] as? String, "status")
        XCTAssertFalse((result?["client"] as? String ?? "").isEmpty)

        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "the socket goes when access is off")
    }

    /// A client that gives up while its request waits (an unanswered prompt,
    /// Ctrl-C on the CLI) closes the socket before the reply. Writing that
    /// reply must fail quietly, not raise SIGPIPE and end Portside.
    func testAClientThatLeavesEarlyDoesNotTakePortsideWithIt() throws {
        let path = root.appendingPathComponent("agent.sock").path
        let server = AgentServer(socketPath: path) { request, _ in
            usleep(300_000)
            return AgentProtocol.Response(id: request.id, result: .string(String(repeating: "x", count: 200_000)))
        }
        try server.start()
        defer { server.stop() }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let bytes = Array(path.utf8)
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(ok, 0)
        let line = Array((#"{"id":1,"method":"status"}"# + "\n").utf8)
        _ = write(fd, line, line.count)
        close(fd)
        usleep(800_000)

        // Still here, and still answering.
        let reply = try Self.roundTrip(path, #"{"id":2,"method":"status"}"#)
        XCTAssertEqual(reply["id"] as? Int, 2)
    }

    nonisolated static func roundTrip(_ path: String, _ line: String) throws -> [String: Any] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let bytes = Array(path.utf8)
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else { throw POSIXError(.ECONNREFUSED) }
        let data = Array((line + "\n").utf8)
        _ = write(fd, data, data.count)
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var reply = [UInt8]()
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            reply += buffer[0..<n]
            if buffer[n - 1] == 0x0A { break }
        }
        return try JSONSerialization.jsonObject(with: Data(reply)) as? [String: Any] ?? [:]
    }

    // MARK: - Controller

    /// `loginShell`: the user's real login shell, for the tests that are
    /// about how one starts up. Everything else gets `zsh -f` — no rc files —
    /// so many shells at once under `--parallel` reach a prompt in time (#31).
    private func controller(_ entries: [SessionEntry], loginShell: Bool = false)
        -> (AgentController, SessionStore, SessionManager) {
        let store = SessionStore(fileURL: root.appendingPathComponent("portside.json"))
        entries.forEach(store.upsert)
        let sessions = SessionManager()
        if !loginShell { sessions.localShell = ("/bin/zsh", ["-f"]) }
        let agent = AgentController()
        agent.promptTimeout = 5
        agent.approvalArmingDelay = 0
        agent.configure(store: store, sessions: sessions)
        keepAlive = [store, sessions]
        return (agent, store, sessions)
    }

    private let claude = AgentClient(pid: 1, name: "claude", path: "/usr/local/bin/claude")

    /// Runs a request and answers each prompt it raises with the given
    /// choices, in order — the person at the keyboard.
    private func run(_ agent: AgentController, _ method: String, _ params: AgentProtocol.Params = .init(),
                     answering choices: [Int?] = []) async -> AgentProtocol.Response {
        let task = Task { await agent.handle(.init(method: method, params: params), from: claude) }
        for choice in choices {
            for _ in 0..<3000 where agent.prompt == nil { try? await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertNotNil(agent.prompt, "expected a prompt")
            agent.answer(choice)
        }
        return await task.value
    }

    func testOffMeansOffWithNoPrompt() async {
        let (agent, _, _) = controller([host("web1")])
        let r = await run(agent, "hosts")
        XCTAssertEqual(r.error?.code, "denied")
        XCTAssertNil(agent.prompt)
    }

    func testFirstUseAsksOnceThenRemembers() async {
        let (agent, _, _) = controller([host("web1", env: .prod), host("web2")])
        agent.setEnabled(true)
        defer { agent.setEnabled(false) }

        let first = await run(agent, "hosts", .init(query: "env:prod"), answering: [1]) // Read only
        XCTAssertNil(first.error)
        guard case .array(let rows)? = first.result else { return XCTFail() }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(agent.settings.approvals.first?.tier, .read)

        let again = await run(agent, "groups")
        XCTAssertNil(again.error, "approved once, not asked again")

        // Read only doesn't stretch to opening sessions: it asks to upgrade.
        let open = await run(agent, "connect", .init(query: "web2"), answering: [1]) // Don't Allow
        XCTAssertEqual(open.error?.code, "declined")
        XCTAssertEqual(agent.settings.approvals.first?.tier, .read)
    }

    /// Approvals are written with ISO 8601 dates; reading them back has to
    /// agree, or the next launch finds no settings at all — Agent Access off
    /// and every approval gone.
    func testApprovalsSurviveARelaunch() async {
        let (agent, _, _) = controller([host("web1")])
        agent.setEnabled(true)
        _ = await run(agent, "hosts", answering: [1]) // Read only
        XCTAssertEqual(agent.settings.approvals.count, 1)
        agent.setEnabled(true)   // stays on

        let (relaunched, _, _) = controller([host("web1")])
        defer { relaunched.setEnabled(false) }
        XCTAssertTrue(relaunched.settings.enabled, "Agent Access is still on")
        XCTAssertEqual(relaunched.settings.approvals.map(\.name), ["claude"], "and remembers who it approved")
    }

    func testDenyingIsRememberedBrieflySoItCantNag() async {
        let (agent, _, _) = controller([host("web1")])
        agent.setEnabled(true)
        defer { agent.setEnabled(false) }
        let r = await run(agent, "hosts", answering: [2])
        XCTAssertEqual(r.error?.code, "declined")
        let again = await run(agent, "hosts")
        XCTAssertEqual(again.error?.code, "denied")
        XCTAssertNil(agent.prompt, "a refused program doesn't get to re-prompt straight away")
    }

    /// The rule that matters most: a protected host is never opened by an
    /// agent without a person seeing its name and saying yes.
    func testProtectedHostsAskEveryTimeAndCancelOpensNothing() async {
        let (agent, _, sessions) = controller([host("db1", protected: true), host("web1")])
        agent.setEnabled(true)
        defer { agent.setEnabled(false) }
        _ = await run(agent, "status", answering: [0]) // approve read+open

        let r = await run(agent, "connect", .init(query: "db1"), answering: [1]) // Cancel
        XCTAssertEqual(r.error?.code, "declined")
        XCTAssertTrue(sessions.tabs.allSatisfy(\.isStartPage), "nothing opened")
    }

    func testUnansweredPromptTimesOutAsANo() async {
        let (agent, _, sessions) = controller((1...4).map { host("h\($0)") })
        agent.setEnabled(true)
        agent.setConnectCap(2)
        agent.promptTimeout = 0.3
        defer { agent.setEnabled(false) }
        _ = await run(agent, "status", answering: [0])

        let r = await agent.handle(.init(method: "connect", params: .init(query: "lab")), from: claude)
        XCTAssertEqual(r.error?.code, "timed_out")
        XCTAssertTrue(sessions.tabs.allSatisfy(\.isStartPage))
    }

    /// A Return already in flight — typed into a pane as the prompt appears —
    /// must not approve anything. Refusing is never delayed.
    func testApprovalIsIgnoredUntilThePromptHasBeenSeen() async {
        let (agent, _, _) = controller([host("web1")])
        agent.setEnabled(true)
        agent.approvalArmingDelay = 0.5
        defer { agent.setEnabled(false) }

        let task = Task { await agent.handle(.init(method: "hosts"), from: claude) }
        for _ in 0..<3000 where agent.prompt == nil { try? await Task.sleep(nanoseconds: 5_000_000) }
        agent.answer(0) // instantly: ignored
        XCTAssertNotNil(agent.prompt, "an approval in the first moment doesn't count")
        try? await Task.sleep(nanoseconds: 600_000_000)
        agent.answer(0)
        let r = await task.value
        XCTAssertNil(r.error)

        let other = AgentClient(pid: 2, name: "other", path: "")
        let refused = Task { await agent.handle(.init(method: "hosts"), from: other) }
        for _ in 0..<3000 where agent.prompt == nil { try? await Task.sleep(nanoseconds: 5_000_000) }
        agent.answer(agent.prompt!.refusal) // instantly: refusals always count
        let no = await refused.value
        XCTAssertEqual(no.error?.code, "declined")
    }

    func testRefusalIsTheLastChoiceOfEveryPrompt() async {
        let (agent, _, _) = controller([host("web1")])
        agent.setEnabled(true)
        defer { agent.setEnabled(false) }
        let task = Task { await agent.handle(.init(method: "hosts"), from: claude) }
        for _ in 0..<3000 where agent.prompt == nil { try? await Task.sleep(nanoseconds: 5_000_000) }
        let prompt = agent.prompt!
        XCTAssertTrue(prompt.choices[prompt.refusal].contains("Don"), prompt.choices.joined(separator: "|"))
        agent.answer(prompt.refusal)
        _ = await task.value
    }

    func testActivityIsLoggedToDisk() async throws {
        let (agent, _, _) = controller([host("web1")])
        agent.setEnabled(true)
        defer { agent.setEnabled(false) }
        _ = await run(agent, "hosts", .init(query: "web"), answering: [1])
        let log = try String(contentsOf: XCTUnwrap(agent.logURL), encoding: .utf8)
        XCTAssertTrue(log.contains("\"client\":\"claude\""))
        XCTAssertTrue(log.contains("\"method\":\"hosts\""))
        XCTAssertFalse(log.contains("password"))
    }

    // MARK: - Input tier

    func testKeystrokesDropControlCharactersAndMapReturn() {
        func keys(_ t: String?, enter: Bool = false, key: String? = nil) -> String? {
            try? AgentPolicy.keystrokes(text: t, enter: enter, key: key).get()
        }
        XCTAssertEqual(keys("uptime", enter: true), "uptime\r")
        XCTAssertEqual(keys("ls\nwhoami"), "ls\rwhoami")
        // An escape sequence or ^D can't ride in on text.
        XCTAssertEqual(keys("a\u{1B}[201~b\u{4}c"), "a[201~bc")
        XCTAssertEqual(keys(nil, key: "ctrl-c"), "\u{3}")
        XCTAssertNil(keys(nil, key: "f13"))
        XCTAssertNil(keys("\u{1B}\u{7}"), "nothing left is an error, not an empty send")
        XCTAssertNil(keys(nil))
    }

    func testScreenTextIsPlainAndTrimmed() {
        let raw = "one\ntwo\u{7}  \nthree\n\n\n"
        XCTAssertEqual(AgentPolicy.screenText(raw, lines: 10), "one\ntwo\nthree")
        XCTAssertEqual(AgentPolicy.screenText(raw, lines: 2), "two\nthree")
    }

    /// A line longer than the terminal comes back whole. CI's hostname made
    /// the prompt long enough to wrap an echoed command, and the screen read
    /// split it in two, so an agent searching for it found nothing.
    @MainActor
    func testScreenReadJoinsSoftWrappedRows() {
        let h = TerminalHarness(cols: 10, rows: 5)
        h.feed("abcdefghij klmnopq\r\nnext\r\nhard\r\nbreak")
        XCTAssertEqual(AgentController.screenLines(h.terminal)
                        .components(separatedBy: "\n").filter { !$0.isEmpty },
                       ["abcdefghij klmnopq", "next", "hard", "break"],
                       "the wrapped row joins its line, the space at the edge kept; real newlines stay")
    }

    func testTypingIsRefusedUntilItsOwnSwitchIsOn() async {
        let (agent, _, _) = controller([host("web1")])
        agent.setEnabled(true)
        defer { agent.setEnabled(false) }
        _ = await run(agent, "status", answering: [0]) // read + open
        let r = await run(agent, "send", .init(pane: "web1", text: "id"))
        XCTAssertEqual(r.error?.code, "denied")
        XCTAssertNil(agent.prompt, "with typing off, nobody is even asked")
    }

    /// The whole path on a real shell: approval to type, the per-pane
    /// question, the text arriving, the screen read back as untrusted data —
    /// and protected hosts and multi-line input asking again.
    func testTypingIntoARealPaneAndReadingItBack() async throws {
        let (agent, _, sessions) = controller([])
        agent.setEnabled(true)
        agent.setAllowInput(true)
        defer { agent.setEnabled(false); sessions.tabs.forEach(sessions.closeTab) }
        sessions.openLocalShell()
        let pane = try XCTUnwrap(sessions.tabs.last?.leaves.first)
        // Let the shell come up before typing.
        try await waitForPrompt(pane)

        let marker = "portside-agent-\(UUID().uuidString.prefix(6))"
        // First: approve typing for the client, then "Allow for This Pane".
        let sent = await run(agent, "send", .init(pane: pane.id.uuidString, text: "echo \(marker)", enter: true),
                             answering: [0, 0])
        XCTAssertNil(sent.error, "\(String(describing: sent.error))")
        XCTAssertNotNil(agent.agentTypedAt[pane.id], "the pane shows it is being typed into")

        // The same pane again: no question.
        let again = await run(agent, "send", .init(pane: pane.id.uuidString, key: "enter"))
        XCTAssertNil(again.error)

        // Multi-line always asks, and Don't Allow types nothing.
        let multi = await run(agent, "send", .init(pane: pane.id.uuidString, text: "echo a\necho b"),
                              answering: [1])
        XCTAssertEqual(multi.error?.code, "declined")

        var text = ""
        for _ in 0..<200 {
            let screen = await run(agent, "screen", .init(pane: pane.id.uuidString, lines: 50))
            guard case .object(let o)? = screen.result else { return XCTFail("\(String(describing: screen.error))") }
            XCTAssertEqual(o["untrusted"], .bool(true))
            if case .string(let t)? = o["text"] { text = t }
            if text.components(separatedBy: marker).count >= 3 { break } // the command line and its output
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertGreaterThanOrEqual(text.components(separatedBy: marker).count, 3, text)
        XCTAssertFalse(text.contains("echo b"), "the declined multi-line input never arrived")
    }

    func testTurningTypingOffTakesItBack() async {
        let (agent, _, _) = controller([])
        agent.setEnabled(true)
        agent.setAllowInput(true)
        defer { agent.setEnabled(false) }
        let r = await run(agent, "send", .init(pane: "nothing", text: "x"), answering: [0]) // grants input
        XCTAssertEqual(r.error?.code, "not_found")
        XCTAssertEqual(agent.settings.approvals.first?.tier, .input)
        agent.setAllowInput(false)
        XCTAssertEqual(agent.settings.approvals.first?.tier, .open)
    }

    /// "What did that print?" on the pane the user is looking at: the command
    /// boundaries come from shell integration, emitted here by hand exactly as
    /// the injected snippet would on a host.
    func testLastCommandOnTheCurrentPane() async throws {
        let (agent, _, sessions) = controller([])
        agent.setEnabled(true)
        agent.setAllowInput(true)
        defer { agent.setEnabled(false); sessions.tabs.forEach(sessions.closeTab) }
        sessions.openLocalShell()
        let pane = try XCTUnwrap(sessions.tabs.last?.leaves.first)
        XCTAssertNotNil(pane.terminalView.outputCapture, "captured while typing is allowed")
        try await waitForPrompt(pane)

        let marker = "agent-\(UUID().uuidString.prefix(6))"
        // printf turns \033 into ESC in the *output*; the typed line itself
        // carries only backslashes, so it isn't mistaken for a mark.
        let line = "printf '\\033]133;C\\007'; echo \(marker); false; printf '\\033]133;D;1\\007'"
        let sent = await run(agent, "send", .init(pane: "current", text: line, enter: true), answering: [0, 0])
        XCTAssertNil(sent.error, "\(String(describing: sent.error))")

        var output = ""
        for _ in 0..<200 {
            let r = await run(agent, "last-command", .init(pane: "current"))
            if case .object(let o)? = r.result, case .array(let cmds)? = o["commands"],
               case .object(let first)? = cmds.first, first["finished"] == .bool(true) {
                if case .string(let t)? = first["output"] { output = t }
                XCTAssertEqual(first["exitCode"], JSONValue(1))
                XCTAssertEqual(o["untrusted"], .bool(true))
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(output, marker, "just that command's output: no prompt, no typed line")
    }

    func testTurningTypingOffStopsCapturing() {
        let (agent, _, sessions) = controller([])
        agent.setEnabled(true)
        agent.setAllowInput(true)
        XCTAssertTrue(sessions.capturesCommandOutput)
        agent.setAllowInput(false)
        XCTAssertFalse(sessions.capturesCommandOutput)
        agent.setAllowInput(true)
        agent.setEnabled(false)
        XCTAssertFalse(sessions.capturesCommandOutput, "access off means nothing is kept")
    }

    /// Claude running in a Portside pane must never read or type into its own
    /// conversation by asking for "current".
    func testCurrentNeverMeansTheCallersOwnPane() async throws {
        let (agent, _, sessions) = controller([])
        agent.setEnabled(true)
        agent.setAllowInput(true)
        defer { agent.setEnabled(false); sessions.tabs.forEach(sessions.closeTab) }
        sessions.openLocalShell()
        let pane = try XCTUnwrap(sessions.tabs.last?.leaves.first)
        let insidePane = AgentClient(pid: pane.terminalView.process.shellPid, name: "claude", path: "")
        // Grant typing up front (to a pane that doesn't exist), so the only
        // question left is which pane "current" means.
        _ = await run(agent, "send", .init(pane: "nothing", text: "x"), answering: [0])
        XCTAssertEqual(agent.settings.approvals.first?.tier, .input)
        let task = Task { await agent.handle(.init(method: "screen", params: .init(pane: "current")),
                                             from: insidePane) }
        // Had "current" resolved to the caller's pane, it would now be asking
        // to read it. It mustn't get that far.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(agent.prompt, "current resolved to the agent's own pane")
        agent.answer(nil)
        let r = await task.value
        XCTAssertEqual(r.error?.code, "not_found", "\(String(describing: r.error))")
    }

    /// Every prompt the first typing request can raise has to fit in an alert
    /// with its refusal still on screen.
    func testFirstTypingRequestPromptKeepsItsRefusal() async {
        let (agent, _, _) = controller([])
        agent.setEnabled(true)
        agent.setAllowInput(true)
        defer { agent.setEnabled(false) }
        let task = Task { await agent.handle(.init(method: "send", params: .init(pane: "x", text: "y")), from: claude) }
        for _ in 0..<3000 where agent.prompt == nil { try? await Task.sleep(nanoseconds: 5_000_000) }
        let prompt = agent.prompt!
        XCTAssertLessThanOrEqual(prompt.choices.count, AgentController.maxChoices, prompt.choices.joined(separator: "|"))
        XCTAssertTrue(prompt.choices[prompt.refusal].hasPrefix("Don"))
        agent.answer(prompt.refusal)
        _ = await task.value
    }

    /// Remote password prompts are invisible to the tty, so the last line is
    /// read too — leaning towards refusing.
    func testSecretPromptTextIsRecognised() {
        for prompt in ["Password:", "[sudo] password for tim:", "Enter passphrase for key '/x/id_ed25519':",
                       "Verification code:", "tim@host's password:", "PIN:", "Enter OTP >"] {
            XCTAssertTrue(AgentPolicy.looksLikeSecretPrompt(prompt), prompt)
        }
        for line in ["tim@hopper:~$", "password reset complete", "grep password config.yml", ""] {
            XCTAssertFalse(AgentPolicy.looksLikeSecretPrompt(line), line)
        }
    }

    // MARK: - Don't Ask

    func testDontAskLetsAProgramInAndClosesWithoutAPrompt() async throws {
        let (agent, _, sessions) = controller([])
        agent.setEnabled(true)
        agent.setDontAskAllowed(true)
        defer { agent.setEnabled(false); sessions.tabs.forEach(sessions.closeTab) }
        sessions.openLocalShell()
        let tab = try XCTUnwrap(sessions.tabs.last)

        // A first-time program, closing a tab it didn't open: normally two prompts.
        let r = await agent.handle(.init(method: "close", params: .init(ids: [tab.id.uuidString])), from: claude)
        XCTAssertNil(r.error, "\(String(describing: r.error))")
        XCTAssertNil(agent.prompt)
        XCTAssertEqual(agent.settings.approvals.first?.tier, .open, "granted the most on offer")
        XCTAssertFalse(sessions.tabs.contains { $0.id == tab.id })
        let log = try String(contentsOf: XCTUnwrap(agent.logURL), encoding: .utf8)
        XCTAssertTrue(log.contains("auto-approved"), "every skipped prompt is on record")
    }

    /// Protected hosts are the user's "be careful here"; Don't Ask alone
    /// doesn't override it.
    func testDontAskStillAsksAboutProtectedHosts() async {
        let (agent, _, sessions) = controller([host("db1", protected: true)])
        agent.setEnabled(true)
        agent.setDontAskAllowed(true)
        defer { agent.setEnabled(false) }
        let task = Task { await agent.handle(.init(method: "connect", params: .init(query: "db1")), from: claude) }
        for _ in 0..<3000 where agent.prompt == nil { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertNotNil(agent.prompt, "a protected host still asks")
        agent.answer(agent.prompt?.refusal)
        let r = await task.value
        XCTAssertEqual(r.error?.code, "declined")
        XCTAssertTrue(sessions.tabs.allSatisfy(\.isStartPage))

        XCTAssertTrue(agent.skipsPrompt(protected: false))
        XCTAssertFalse(agent.skipsPrompt(protected: true))
        agent.setDontAskIncludesProtected(true)
        XCTAssertTrue(agent.skipsPrompt(protected: true), "only when explicitly included")
    }

    /// The floors Don't Ask can't lower: typing needs its own switch, and
    /// nothing is typed at a password prompt.
    func testDontAskNeverTypesWithoutTheSwitchOrIntoASecretPrompt() async throws {
        let (agent, _, sessions) = controller([])
        agent.setEnabled(true)
        agent.setDontAskAllowed(true)
        defer { agent.setEnabled(false); sessions.tabs.forEach(sessions.closeTab) }
        sessions.openLocalShell()
        let pane = try XCTUnwrap(sessions.tabs.last?.leaves.first)

        let off = await agent.handle(.init(method: "send", params: .init(pane: pane.id.uuidString, text: "id")),
                                     from: claude)
        XCTAssertEqual(off.error?.code, "denied", "typing off means off, whatever Don't Ask says")

        agent.setAllowInput(true)
        try await waitForPrompt(pane)
        pane.sendText("read -s portside_secret\r")
        for _ in 0..<200 where !pane.isReadingSecret { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(pane.isReadingSecret)
        let secret = await agent.handle(.init(method: "send", params: .init(pane: pane.id.uuidString,
                                                                            text: "hunter2", enter: true)),
                                        from: claude)
        XCTAssertEqual(secret.error?.code, "denied", "never typed at a password prompt")
        XCTAssertNil(agent.prompt)
        pane.sendText("\r")
    }

    func testDontAskEndsWithTheSessionUnlessKept() {
        let (agent, store, sessions) = controller([])
        agent.setEnabled(true)
        agent.setDontAskAllowed(true)
        let next = AgentController()
        next.configure(store: store, sessions: sessions)
        XCTAssertFalse(next.settings.dontAsk, "a relaunch starts with confirmations back on")

        XCTAssertTrue(next.settings.dontAskAllowed, "off, but still allowed: one click to resume")
        next.setDontAsk(true)
        next.setDontAskPersists(true)
        let after = AgentController()
        after.configure(store: store, sessions: sessions)
        XCTAssertTrue(after.settings.dontAsk)
        after.setEnabled(false)
        next.setEnabled(false)
        agent.setEnabled(false)
    }

    // MARK: - Reading a whole tab

    /// "What's going on across these?" — every pane of the tab in one call,
    /// behind one question, and never the caller's own pane.
    func testReadingTheWholeTabAsksOnceAndSkipsTheCallersPane() async throws {
        let (agent, _, sessions) = controller([])
        agent.setEnabled(true)
        agent.setAllowInput(true)
        defer { agent.setEnabled(false); sessions.tabs.forEach(sessions.closeTab) }
        sessions.openLocalShell()
        sessions.splitActivePane(.horizontal)
        sessions.splitActivePane(.vertical)
        let leaves = try XCTUnwrap(sessions.selectedTab?.leaves)
        XCTAssertEqual(leaves.count, 3)
        _ = await run(agent, "send", .init(pane: "none", text: "x"), answering: [0]) // grant typing tier

        let task = Task { await agent.handle(.init(method: "screen", params: .init(pane: "tab")), from: claude) }
        for _ in 0..<3000 where agent.prompt == nil { try? await Task.sleep(nanoseconds: 5_000_000) }
        let prompt = try XCTUnwrap(agent.prompt)
        XCTAssertTrue(prompt.title.contains("3 panes"), prompt.title)
        agent.answer(0)
        let r = await task.value
        guard case .object(let o)? = r.result, case .array(let panes)? = o["panes"] else {
            return XCTFail("\(String(describing: r.error))")
        }
        XCTAssertEqual(panes.count, 3)
        XCTAssertEqual(o["untrusted"], .bool(true))
        XCTAssertNil(agent.prompt, "one question covered all three")

        // The same read from inside the second pane leaves that pane out.
        let inside = AgentClient(pid: leaves[1].terminalView.process.shellPid, name: "claude", path: "")
        let mine = await agent.handle(.init(method: "screen", params: .init(pane: "tab")), from: inside)
        guard case .object(let m)? = mine.result, case .array(let others)? = m["panes"] else {
            return XCTFail("\(String(describing: mine.error))")
        }
        let ids = others.compactMap { row -> String? in
            if case .object(let p) = row, case .string(let id)? = p["pane"] { return id }
            return nil
        }
        XCTAssertEqual(ids.count, 2)
        XCTAssertFalse(ids.contains(leaves[1].id.uuidString), "never the caller's own pane")
    }

    /// A tab with one pane still answers as a list: a client asking for a tab
    /// handles one shape, not two (issue #24).
    func testReadingATabOfOnePaneIsStillAList() async throws {
        let (agent, _, sessions) = controller([])
        agent.setEnabled(true)
        agent.setAllowInput(true)
        defer { agent.setEnabled(false); sessions.tabs.forEach(sessions.closeTab) }
        sessions.openLocalShell()
        _ = await run(agent, "send", .init(pane: "none", text: "x"), answering: [0]) // grant typing tier

        let r = await run(agent, "screen", .init(pane: "tab"), answering: [0])
        guard case .object(let o)? = r.result, case .array(let panes)? = o["panes"] else {
            return XCTFail("expected {panes: [...]}, got \(String(describing: r.result)) \(String(describing: r.error))")
        }
        XCTAssertEqual(panes.count, 1)
    }

    /// The popover pauses and resumes; only Settings allows or disallows —
    /// and disallowing resets the opt-ins, so the next enable is the
    /// defaults the warning describes.
    func testDontAskPausesFromThePopoverAndResetsWhenDisallowed() async {
        let (agent, _, _) = controller([host("web1")])
        agent.setEnabled(true)
        defer { agent.setEnabled(false) }
        XCTAssertFalse(agent.settings.dontAskPersists, "keep-on is opt-in")
        XCTAssertFalse(agent.settings.dontAskIncludesProtected, "protected is opt-in")

        agent.setDontAsk(true)
        XCTAssertFalse(agent.skipsPrompt(protected: false), "the popover can't turn on what Settings hasn't allowed")

        agent.setDontAskAllowed(true)
        agent.setDontAskIncludesProtected(true)
        agent.setDontAskPersists(true)
        agent.setDontAsk(false)
        XCTAssertFalse(agent.skipsPrompt(protected: false))
        let paused = await run(agent, "hosts", answering: [0])
        XCTAssertNil(paused.error, "disabled means asked again")
        agent.setDontAsk(true)
        XCTAssertTrue(agent.skipsPrompt(protected: false))

        agent.setDontAskAllowed(false)
        XCTAssertFalse(agent.settings.dontAskPersists)
        XCTAssertFalse(agent.settings.dontAskIncludesProtected)
        agent.setDontAskAllowed(true)
        XCTAssertFalse(agent.skipsPrompt(protected: true), "a fresh enable doesn't remember including protected hosts")
        XCTAssertFalse(agent.settings.dontAskPersists, "nor keeping it on across quits")
    }

    // MARK: - Scoped Don't Ask

    func testDontAskScopeCoversOnlyMatchingHosts() async {
        let lab = host("lab1", env: .dev)
        var prod = host("web1", env: .prod)
        prod.folder = "prod"
        var prod2 = host("web2", env: .prod)
        prod2.folder = "prod"
        let (agent, _, sessions) = controller([lab, prod, prod2])
        agent.setEnabled(true)
        agent.setDontAskAllowed(true)
        agent.setDontAskScope("env:dev")
        defer { agent.setEnabled(false) }

        XCTAssertTrue(agent.skipsPrompt(protected: false, hosts: [lab]))
        XCTAssertFalse(agent.skipsPrompt(protected: false, hosts: [prod]), "outside the scope asks")
        XCTAssertFalse(agent.skipsPrompt(protected: false, hosts: [lab, prod]), "every host must match")
        XCTAssertFalse(agent.skipsPrompt(protected: false, hosts: [nil]), "a local shell has no host to match")
        XCTAssertTrue(agent.skipsPrompt(protected: false), "letting a program in isn't about a host")
        agent.setDontAskScope("/[/")
        XCTAssertFalse(agent.skipsPrompt(protected: false, hosts: [lab]), "a broken scope covers nothing")
        XCTAssertNil(agent.scopeCoverage("/[/"))
        agent.setDontAskScope("env:dev")
        XCTAssertEqual(agent.scopeCoverage("env:dev")?.matched, 1)

        // Two prod hosts over a cap of one needs a confirmation; being
        // outside the scope, Don't Ask must not answer it.
        _ = await run(agent, "status")
        agent.setConnectCap(1)
        let task = Task { await agent.handle(.init(method: "connect", params: .init(query: "env:prod")), from: claude) }
        for _ in 0..<3000 where agent.prompt == nil { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertNotNil(agent.prompt)
        agent.answer(agent.prompt?.refusal)
        _ = await task.value
        XCTAssertTrue(sessions.tabs.allSatisfy(\.isStartPage))

        agent.setDontAskAllowed(false)
        XCTAssertEqual(agent.settings.dontAskScope, "", "disallowing resets the scope too")
    }

    // MARK: - Waiting

    /// Type, run, wait, read in one call — on a real shell, with the command
    /// boundaries a host's shell integration would print.
    func testSendWithWaitReturnsTheCommandsResult() async throws {
        let (agent, _, sessions) = controller([])
        agent.setEnabled(true)
        agent.setAllowInput(true)
        agent.setDontAskAllowed(true)
        defer { agent.setEnabled(false); sessions.tabs.forEach(sessions.closeTab) }
        sessions.openLocalShell()
        let pane = try XCTUnwrap(sessions.tabs.last?.leaves.first)
        try await waitForPrompt(pane)
        // Local shells aren't in a host scope; the default (all) covers them.

        let marker = "waited-\(UUID().uuidString.prefix(6))"
        let line = "printf '\\033]133;C\\007'; sleep 1; echo \(marker); printf '\\033]133;D;0\\007'"
        let started = Date()
        let r = await agent.handle(.init(method: "send", params: .init(pane: pane.id.uuidString, text: line,
                                                                       enter: true, wait: 20)), from: claude)
        guard case .object(let o)? = r.result else { return XCTFail("\(String(describing: r.error))") }
        XCTAssertEqual(o["waitedOut"], .bool(false))
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 0.9, "it waited for the sleep")
        guard case .object(let row)? = o["result"], case .array(let cmds)? = row["commands"],
              case .object(let cmd)? = cmds.first else { return XCTFail("no result: \(o)") }
        XCTAssertEqual(cmd["output"], .string(marker))
        XCTAssertEqual(cmd["exitCode"], JSONValue(0))
    }

    func testWaitGivesUpAtItsTimeoutAndSaysSo() async throws {
        let (agent, _, sessions) = controller([])
        agent.setEnabled(true)
        agent.setAllowInput(true)
        agent.setDontAskAllowed(true)
        defer { agent.setEnabled(false); sessions.tabs.forEach(sessions.closeTab) }
        sessions.openLocalShell()
        let pane = try XCTUnwrap(sessions.tabs.last?.leaves.first)
        let started = Date()
        let r = await agent.handle(.init(method: "last-command", params: .init(pane: pane.id.uuidString, wait: 1)),
                                   from: claude)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        if case .object(let o)? = r.result { XCTAssertEqual(o["waitedOut"], .bool(true)) }
        else { XCTAssertNotNil(r.error, "nothing ran: either an empty result or a not-found, never a hang") }
    }

    /// Waits until the shell's line editor is running — echo and canonical
    /// mode both off — rather than for a fixed time. A login shell with a
    /// heavy rc took seven seconds to get there idle, and far longer with the
    /// suite running in parallel; typing before then lands in the shell's
    /// startup, not at its prompt.
    /// Don't Ask without "also for protected hosts" still asks before an
    /// agent reads a protected pane, as it does before typing into one.
    func testDontAskStillAsksBeforeReadingAProtectedPane() async throws {
        var entry = SessionEntry(name: "vault", hostname: "", kind: .container)
        entry.isProtected = true
        entry.container = ContainerTarget(engine: .nerdctl, name: "portside-test-\(UUID().uuidString.prefix(6))")
        let (agent, _, sessions) = controller([entry])
        agent.setEnabled(true)
        agent.setAllowInput(true)
        agent.setDontAskAllowed(true)
        defer { agent.setEnabled(false); sessions.tabs.forEach(sessions.closeTab) }
        sessions.connect(to: entry)
        let pane = try XCTUnwrap(sessions.tabs.last?.leaves.first)

        let task = Task { await agent.handle(.init(method: "screen", params: .init(pane: pane.id.uuidString)),
                                             from: claude) }
        for _ in 0..<3000 where agent.prompt == nil { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(agent.prompt, "a protected pane's screen was read without asking")
        agent.answer(agent.prompt?.refusal)
        let r = await task.value
        XCTAssertEqual(r.error?.code, "declined")
    }

    /// A password prompt that turns up while the user is being asked — a
    /// remote one, which only the screen shows — stops the text from going
    /// into it once they say yes.
    func testAPasswordPromptThatAppearsDuringTheQuestionIsNotTypedInto() async throws {
        let (agent, _, sessions) = controller([])
        agent.setEnabled(true)
        agent.setAllowInput(true)
        defer { agent.setEnabled(false); sessions.tabs.forEach(sessions.closeTab) }
        sessions.openLocalShell()
        let pane = try XCTUnwrap(sessions.tabs.last?.leaves.first)
        try await waitForPrompt(pane)

        let secret = "agent-text-\(UUID().uuidString.prefix(6))"
        let task = Task { await agent.handle(.init(method: "send", params: .init(pane: pane.id.uuidString,
                                                                                 text: secret)), from: claude) }
        // First the program's approval, then the pane's.
        for _ in 0..<3000 where agent.prompt == nil { try? await Task.sleep(nanoseconds: 10_000_000) }
        agent.answer(0)
        for _ in 0..<3000 where agent.prompt == nil { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(agent.prompt, "the pane's own question")

        // Meanwhile the session reaches a password prompt (echo still on, as
        // a remote one looks from here).
        pane.sendText("printf 'Password: '; read -r x\r")
        for _ in 0..<300 {
            if AgentPolicy.screenText(AgentController.screenLines(pane.terminalView.getTerminal()), lines: 1)
                .hasSuffix("Password:") { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        agent.answer(0)
        let r = await task.value
        XCTAssertNotNil(r.error, "typed into a password prompt")
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(AgentController.screenLines(pane.terminalView.getTerminal()).contains(secret))
    }

    /// Letting one program into a pane doesn't let another in: the question
    /// named the program.
    func testPaneConsentBelongsToTheProgramThatWasAsked() async throws {
        let (agent, _, sessions) = controller([])
        agent.setEnabled(true)
        agent.setAllowInput(true)
        defer { agent.setEnabled(false); sessions.tabs.forEach(sessions.closeTab) }
        sessions.openLocalShell()
        let pane = try XCTUnwrap(sessions.tabs.last?.leaves.first)
        try await waitForPrompt(pane)

        let first = await run(agent, "screen", .init(pane: pane.id.uuidString), answering: [0, 0])
        XCTAssertNil(first.error)
        let codex = AgentClient(pid: 2, name: "codex", path: "/usr/local/bin/codex")
        let task = Task { await agent.handle(.init(method: "screen", params: .init(pane: pane.id.uuidString)),
                                             from: codex) }
        for _ in 0..<300 where agent.prompt == nil { try? await Task.sleep(nanoseconds: 10_000_000) }
        agent.answer(0)   // codex may use Portside, with typing
        for _ in 0..<300 where agent.prompt == nil { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(agent.prompt, "codex read a pane only claude was let into")
        XCTAssertTrue(agent.prompt?.title.contains("codex") == true, "\(String(describing: agent.prompt?.title))")
        agent.answer(agent.prompt?.refusal)
        let r = await task.value
        XCTAssertEqual(r.error?.code, "declined")
    }

    /// A wait on a tab answers in the tab's shape — a list — like the same
    /// read without a wait.
    func testWaitingOnATabKeepsTheListShape() async throws {
        let (agent, _, sessions) = controller([])
        agent.setEnabled(true)
        agent.setAllowInput(true)
        defer { agent.setEnabled(false); sessions.tabs.forEach(sessions.closeTab) }
        sessions.openLocalShell()
        let pane = try XCTUnwrap(sessions.tabs.last?.leaves.first)
        try await waitForPrompt(pane)
        sessions.selectedTabID = sessions.tabs.last?.id
        _ = await run(agent, "screen", .init(pane: pane.id.uuidString), answering: [0, 0])
        _ = await run(agent, "send", .init(pane: pane.id.uuidString,
                                           text: "printf '\\033]133;C\\007'; echo hi; printf '\\033]133;D;0\\007'",
                                           enter: true, wait: 10))
        let r = await run(agent, "last-command", .init(pane: "tab", wait: 1))
        guard case .object(let o)? = r.result else { return XCTFail("\(String(describing: r.error))") }
        XCTAssertNotNil(o["panes"], "\(o.keys)")
        XCTAssertNotNil(o["waitedOut"])
    }

    /// More than five commands finishing after a wait began push the one it
    /// was for out. The answer says so, rather than returning a newer command.
    func testAWaitTargetThatWasPushedOutIsntReplacedByANewerCommand() async throws {
        let (agent, _, sessions) = controller([])
        agent.setEnabled(true)
        agent.setAllowInput(true)
        defer { agent.setEnabled(false); sessions.tabs.forEach(sessions.closeTab) }
        sessions.openLocalShell()
        let pane = try XCTUnwrap(sessions.tabs.last?.leaves.first)
        try await waitForPrompt(pane)
        _ = await run(agent, "screen", .init(pane: pane.id.uuidString), answering: [0, 0])
        let one = "printf '\\033]133;C\\007\\033]133;E;%s\\007' $(printf 'cmd%s' N | base64); echo outN; printf '\\033]133;D;0\\007'"
        let line = (1...7).map { one.replacingOccurrences(of: "N", with: "\($0)") }.joined(separator: "; ")
        let r = await run(agent, "send", .init(pane: pane.id.uuidString, text: line, enter: true, wait: 10))
        guard case .object(let o)? = r.result, case .object(let row)? = o["result"] else {
            return XCTFail("\(String(describing: r.error))")
        }
        // Either the wait caught the first command before the others finished
        // (a busy machine), or they all finished between two looks and it
        // was pushed out — which must be said, never answered with a newer one.
        if case .array(let cmds)? = row["commands"], case .object(let c)? = cmds.first {
            XCTAssertEqual(c["command"], .string("cmd1"), "answered with a command that wasn't the one waited for")
        } else {
            guard case .string(let error)? = row["error"] else { return XCTFail("\(row)") }
            XCTAssertTrue(error.contains("finished"), error)
        }
    }

    /// Setting up again for the same library — a window appearing again —
    /// doesn't redo the launch-time reset.
    func testConfiguringAgainKeepsASessionOnlyDontAsk() {
        let (agent, store, sessions) = controller([])
        agent.setEnabled(true)
        agent.setDontAskAllowed(true)
        defer { agent.setEnabled(false) }
        agent.setDontAsk(true)
        XCTAssertTrue(agent.settings.dontAsk)
        agent.configure(store: store, sessions: sessions)
        XCTAssertTrue(agent.settings.dontAsk, "reopening a window turned Don't Ask off")
    }

    private func waitForPrompt(_ pane: TerminalSession, seconds: Double = 60) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            var t = termios()
            if let p = pane.terminalView.process, tcgetattr(p.childfd, &t) == 0,
               t.c_lflag & tcflag_t(ECHO) == 0, t.c_lflag & tcflag_t(ICANON) == 0 { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("the shell never reached its prompt")
    }

    // MARK: Container sessions and client names

    /// Claude Code's process is named after its version folder; asking about
    /// "2.1.291" meant every update looked like a new program.
    func testVersionNamedProcessesTakeTheirProgramsName() {
        XCTAssertEqual(AgentServer.displayName("2.1.291", path: "/Users/x/.local/share/claude/versions/2.1.291"),
                       "claude")
        XCTAssertEqual(AgentServer.displayName("1.0.0-beta.2", path: "/opt/tool/1.0.0-beta.2"), "tool")
        XCTAssertEqual(AgentServer.displayName("codex", path: "/usr/local/bin/codex"), "codex")
        XCTAssertEqual(AgentServer.displayName("python3.12", path: "/usr/bin/python3.12"), "python3.12",
                       "a name with a version in it is still a name")
        XCTAssertEqual(AgentServer.displayName("2.1.291", path: ""), "2.1.291", "nothing better to offer")
    }

    /// A container exec that never reaches the container is not "connected",
    /// and a wait on a command there answers once the marker grace has passed
    /// rather than running out its timeout — saying why, in terms that fit a
    /// container.
    func testContainerSessionsSayWhereTheyGotAndDontWaitForNothing() async throws {
        var entry = SessionEntry(name: "box", hostname: "", kind: .container)
        entry.container = ContainerTarget(engine: .nerdctl, name: "portside-test-\(UUID().uuidString.prefix(6))")
        let (agent, _, sessions) = controller([entry])
        agent.setEnabled(true)
        agent.setAllowInput(true)
        agent.setDontAskAllowed(true)
        defer { agent.setEnabled(false); sessions.tabs.forEach(sessions.closeTab) }

        // nerdctl isn't installed here, so the exec fails at once and the
        // local shell comes back.
        let r = await agent.handle(.init(method: "connect", params: .init(ids: [entry.id.uuidString], wait: 90)),
                                   from: claude)
        guard case .object(let o)? = r.result, case .array(let panes)? = o["panes"],
              case .object(let pane)? = panes.first, case .string(let id)? = pane["pane"] else {
            return XCTFail("\(String(describing: r.error)) \(String(describing: r.result))")
        }
        XCTAssertEqual(o["waitedOut"], .bool(false))
        XCTAssertEqual(pane["state"], .string("returned to the local shell"), "the local shell is not the container")

        let started = Date()
        let s = await agent.handle(.init(method: "send", params: .init(pane: id, text: "true", enter: true, wait: 20)),
                                   from: claude)
        XCTAssertLessThan(Date().timeIntervalSince(started), 8, "answered without waiting out the 20s")
        guard case .object(let sent)? = s.result, case .object(let result)? = sent["result"],
              case .string(let error)? = result["error"] else { return XCTFail("\(String(describing: s.result))") }
        XCTAssertTrue(error.contains("container and pod sessions"), error)
        XCTAssertFalse(error.contains("Settings"), "installing integration can't help a container: \(error)")
    }

    // MARK: A quiet pane isn't a pane without integration (PR #30 review)

    /// Markers only arrive when a command starts or finishes. A command that was
    /// already running when typing was switched on — which is when the capture
    /// begins — sends nothing until it ends, so a few quiet seconds prove
    /// nothing. `last --wait` waits on it; `send --wait` (whose text went to that
    /// command) waits for it too.
    func testWaitsDontGiveUpOnACommandThatWasAlreadyRunning() async throws {
        let (agent, _, sessions) = controller([])
        agent.setEnabled(true)
        agent.setDontAskAllowed(true)
        defer { agent.setEnabled(false); sessions.tabs.forEach(sessions.closeTab) }
        sessions.openLocalShell()
        let pane = try XCTUnwrap(sessions.tabs.last?.leaves.first)
        try await waitForPrompt(pane)

        // Started, and its start marker gone by, before the capture exists.
        let marker = "done-\(UUID().uuidString.prefix(6))"
        pane.sendText("printf '\\033]133;C\\007'; sleep 9; echo \(marker); printf '\\033]133;D;0\\007'\r")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        agent.setAllowInput(true)
        XCTAssertNotNil(pane.terminalView.outputCapture)

        let started = Date()
        let sent = Task {
            await agent.handle(.init(method: "send", params: .init(pane: pane.id.uuidString, text: "x",
                                                                   enter: true, wait: 30)), from: claude)
        }
        let last = await agent.handle(.init(method: "last-command", params: .init(pane: pane.id.uuidString, wait: 30)),
                                      from: claude)
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 6, "last --wait gave up on a running command")
        guard case .object(let row)? = last.result, case .array(let cmds)? = row["commands"],
              case .object(let cmd)? = cmds.first, case .string(let out)? = cmd["output"] else {
            return XCTFail("\(String(describing: last))")
        }
        // The terminal echoed what the agent typed while it ran; that's on screen too.
        XCTAssertTrue(out.hasSuffix(marker), out)
        XCTAssertEqual(cmd["exitCode"], JSONValue(0))

        let s = await sent.value
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 6, "send --wait gave up on a running command")
        guard case .object(let o)? = s.result, case .object(let result)? = o["result"],
              case .array(let sc)? = result["commands"], case .object(let c)? = sc.first,
              case .string(let sentOut)? = c["output"] else {
            return XCTFail("\(String(describing: s.result))")
        }
        XCTAssertTrue(sentOut.hasSuffix(marker), sentOut)
        XCTAssertEqual(o["waitedOut"], .bool(false))
    }

    /// A container shell that does carry the integration, opened before typing
    /// was switched on, records its first command like any other: the decision
    /// waits until after the send, not before it.
    func testContainerWithIntegrationIsNotRefusedBeforeItsFirstMarker() async throws {
        var entry = SessionEntry(name: "box", hostname: "", kind: .container)
        entry.container = ContainerTarget(engine: .nerdctl, name: "portside-test-\(UUID().uuidString.prefix(6))")
        let (agent, _, sessions) = controller([entry])
        agent.setEnabled(true)
        agent.setDontAskAllowed(true)
        defer { agent.setEnabled(false); sessions.tabs.forEach(sessions.closeTab) }
        _ = await agent.handle(.init(method: "connect", params: .init(ids: [entry.id.uuidString], wait: 90)),
                               from: claude)
        let pane = try XCTUnwrap(sessions.tabs.last?.leaves.first)
        agent.setAllowInput(true)   // a fresh capture: no marker seen yet

        // The local shell stands in for a container shell with integration.
        let marker = "inside-\(UUID().uuidString.prefix(6))"
        let line = "printf '\\033]133;C\\007'; echo \(marker); printf '\\033]133;D;0\\007'"
        let r = await agent.handle(.init(method: "send", params: .init(pane: pane.id.uuidString, text: line,
                                                                       enter: true, wait: 20)), from: claude)
        guard case .object(let o)? = r.result, case .object(let result)? = o["result"],
              case .array(let cmds)? = result["commands"], case .object(let cmd)? = cmds.first else {
            return XCTFail("refused before the first marker could arrive: \(String(describing: r.result))")
        }
        XCTAssertEqual(cmd["output"], .string(marker))
    }

    /// A login shell runs its rc file's external commands as foreground jobs of
    /// their own — `brew shellenv`, a version manager, here a `sleep`. Taking
    /// one of those for the exec, and the shell's return for the exec failing,
    /// answered "returned to the local shell" before the exec had even been
    /// read (PR #30 review, on a Mac whose zsh takes 8s to start).
    func testASlowShellStartupIsNotTakenForAFailedExec() async throws {
        let home = root.appendingPathComponent("slow-home-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // Two external commands with the shell itself busy in between, as a real
        // rc file is: each command takes the foreground, then the shell has it
        // back while it works through builtins before the next.
        try "sleep 1\ninteger i\nfor ((i = 0; i < 400000; i++)); do :; done\nsleep 2\n"
            .write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let saved = ["HOME", "SHELL"].map { ($0, ProcessInfo.processInfo.environment[$0]) }
        setenv("HOME", home.path, 1)
        setenv("SHELL", "/bin/zsh", 1)
        defer { for (k, v) in saved { if let v { setenv(k, v, 1) } else { unsetenv(k) } } }

        var entry = SessionEntry(name: "box", hostname: "", kind: .container)
        entry.container = ContainerTarget(engine: .nerdctl, name: "portside-test-\(UUID().uuidString.prefix(6))")
        let (agent, _, sessions) = controller([entry], loginShell: true)
        agent.setEnabled(true)
        agent.setAllowInput(true)
        agent.setDontAskAllowed(true)
        defer { agent.setEnabled(false); sessions.tabs.forEach(sessions.closeTab) }

        let started = Date()
        let r = await agent.handle(.init(method: "connect", params: .init(ids: [entry.id.uuidString], wait: 90)),
                                   from: claude)
        guard case .object(let o)? = r.result, case .array(let panes)? = o["panes"],
              case .object(let pane)? = panes.first, case .string(let id)? = pane["pane"] else {
            return XCTFail("\(String(describing: r.error)) \(String(describing: r.result))")
        }
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 3, "answered while the rc file was still running")
        XCTAssertEqual(pane["state"], .string("returned to the local shell"))
        let screen = await agent.handle(.init(method: "screen", params: .init(pane: id)), from: claude)
        guard case .object(let row)? = screen.result, case .string(let text)? = row["text"] else {
            return XCTFail("\(String(describing: screen))")
        }
        XCTAssertTrue(text.contains("not found"), "the exec had run and failed by then: \(text)")
    }
}

