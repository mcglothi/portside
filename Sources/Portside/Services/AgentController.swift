import AppKit
import Foundation

/// Agent Access: lets a program on this Mac — Claude Code, Codex, a script —
/// read the inventory and open sessions in the running app, through the
/// `portside` CLI. See `docs/agent-api-plan.md` and `docs/agent-api.md`.
///
/// The rules, in the order a request meets them:
///
/// 1. **Off unless turned on**, in Settings ▸ Agents. No socket exists until then.
/// 2. **Every client is approved by a person, once.** The first request from a
///    program the user hasn't approved puts a prompt in the app naming it —
///    read only, read and open, or no. A request waits on that answer.
/// 3. **Anything a human would be asked about, an agent is asked about too**,
///    and in the same place: opening a protected host, and — for agents only —
///    opening more hosts at once than the cap. The prompt is answered in the
///    app, never over the socket.
/// 4. **Arming MultiExec is never available.** A grid opens with every pane a
///    member and broadcast off.
/// 5. **Everything is written down**, in `portside.agent.log`, and shown
///    under Settings ▸ Agents.
///
/// What approval is and isn't: it is consent and visibility — the user sees
/// which program wants in and decides. It isn't a wall against malware already
/// running as the user, which could as easily edit the library file. The
/// confirmations in (3) are what protect the fleet.
@MainActor
final class AgentController: ObservableObject {
    struct Approval: Codable, Equatable, Identifiable {
        var name: String
        var path: String
        var tier: AgentProtocol.Tier
        var approvedAt: Date
        var id: String { name }
    }

    struct Settings: Codable, Equatable {
        var enabled = false
        var connectCap = AgentPolicy.defaultConnectCap
        var approvals: [Approval] = []

        enum CodingKeys: String, CodingKey { case enabled, connectCap, approvals }
        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            connectCap = try c.decodeIfPresent(Int.self, forKey: .connectCap) ?? AgentPolicy.defaultConnectCap
            approvals = (try? c.decodeIfPresent([Approval].self, forKey: .approvals)) ?? []
        }
    }

    /// A question for the person at the keyboard. Answered by index into
    /// `choices`, or not at all (timeout, or dismissed) — which is a no.
    struct Prompt: Identifiable {
        let id = UUID()
        var title: String
        var message: String
        /// The last choice is always the refusal, and is the default button:
        /// Return or Escape says no.
        var choices: [String]
        fileprivate var answer: (Int?) -> Void
        /// When it went up. Anything but a refusal in the first moment is
        /// ignored — see `answer(_:)`.
        var shownAt = Date()
        var refusal: Int { choices.count - 1 }
    }

    /// How long a prompt has to have been on screen before it can be
    /// approved. A Return already on its way — typed into a terminal pane
    /// just as the prompt appeared — must not land on it.
    var approvalArmingDelay: TimeInterval = 0.6

    struct Activity: Identifiable, Equatable {
        let id = UUID()
        var date: Date
        var client: String
        var method: String
        var detail: String
        var outcome: String
    }

    @Published private(set) var settings = Settings()
    @Published private(set) var prompt: Prompt?
    @Published private(set) var activity: [Activity] = []
    @Published private(set) var serverError: String?

    /// How long a request waits for someone to answer a prompt.
    var promptTimeout: TimeInterval = 120

    private weak var store: SessionStore?
    private weak var sessions: SessionManager?
    private var server: AgentServer?
    private var queuedPrompts: [Prompt] = []
    /// Tabs an agent opened in this run — the ones it may close without asking.
    private var agentTabs: Set<UUID> = []
    /// Recently refused clients, so a denied program can't re-prompt in a loop.
    private var refusedUntil: [String: Date] = [:]
    private var directory: URL?

    var socketPath: String? { server?.socketPath }

    /// The most recent request, for the toolbar indicator.
    var lastActivity: Date? { activity.first?.date }

    func configure(store: SessionStore, sessions: SessionManager) {
        self.store = store
        self.sessions = sessions
        directory = store.libraryDirectory
        settings = loadSettings()
        if settings.enabled { startServer() }
    }

    // MARK: - Settings

    func setEnabled(_ on: Bool) {
        settings.enabled = on
        saveSettings()
        on ? startServer() : stopServer()
    }

    func setConnectCap(_ cap: Int) {
        settings.connectCap = max(1, cap)
        saveSettings()
    }

    func revoke(_ approval: Approval) {
        settings.approvals.removeAll { $0.name == approval.name }
        saveSettings()
    }

    private var settingsURL: URL? { directory?.appendingPathComponent("portside.agent.json") }
    var logURL: URL? { directory?.appendingPathComponent("portside.agent.log") }

    private func loadSettings() -> Settings {
        guard let url = settingsURL, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return decoded
    }

    private func saveSettings() {
        guard let url = settingsURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(settings).write(to: url, options: .atomic)
    }

    private func startServer() {
        guard server == nil, let directory else { return }
        let path = AgentServer.socketPath(libraryDirectory: directory)
        let server = AgentServer(socketPath: path) { [weak self] request, client in
            guard let self else { return AgentProtocol.Response(id: request.id, error: .denied("Portside is closing.")) }
            return await self.handle(request, from: client)
        }
        do {
            try server.start()
            self.server = server
            serverError = nil
        } catch {
            serverError = "Couldn't open the agent socket: \(error.localizedDescription)"
        }
    }

    func stopServer() {
        server?.stop()
        server = nil
        // Anyone waiting on a prompt gets a no rather than hanging.
        prompt?.answer(nil)
        queuedPrompts.forEach { $0.answer(nil) }
        queuedPrompts = []
        prompt = nil
    }

    // MARK: - Prompts

    func answer(_ choice: Int?) {
        guard let current = prompt else { return }
        if let choice, choice != current.refusal,
           Date().timeIntervalSince(current.shownAt) < approvalArmingDelay {
            return
        }
        prompt = nil
        current.answer(choice)
        if !queuedPrompts.isEmpty {
            var next = queuedPrompts.removeFirst()
            next.shownAt = Date()
            prompt = next
        }
    }

    /// Puts a question in the app and waits for it. Bounces the Dock icon
    /// rather than stealing focus — the user may be typing into a session.
    private func ask(_ title: String, _ message: String, choices: [String]) async -> Int? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int?, Never>) in
            var resumed = false
            let finish: (Int?) -> Void = { choice in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: choice)
            }
            let new = Prompt(title: title, message: message, choices: choices, answer: finish)
            if prompt == nil { prompt = new } else { queuedPrompts.append(new) }
            NSApp?.requestUserAttention(.criticalRequest)
            let id = new.id
            DispatchQueue.main.asyncAfter(deadline: .now() + promptTimeout) { [weak self] in
                guard let self else { return }
                if self.prompt?.id == id { self.answer(nil) }
                if let i = self.queuedPrompts.firstIndex(where: { $0.id == id }) {
                    self.queuedPrompts.remove(at: i).answer(nil)
                }
            }
        }
    }

    // MARK: - Requests

    func handle(_ request: AgentProtocol.Request, from client: AgentClient) async -> AgentProtocol.Response {
        let outcome: Result<JSONValue, AgentProtocol.Failure>
        if !settings.enabled {
            outcome = .failure(.denied("Agent Access is off in Portside (Settings \u{25B8} Agents)."))
        } else if let method = AgentProtocol.Method(rawValue: request.method) {
            switch await authorize(client, for: method.tier) {
            case .success: outcome = await run(method, request.params, client: client)
            case .failure(let failure): outcome = .failure(failure)
            }
        } else {
            outcome = .failure(.badRequest("Unknown method \u{201C}\(request.method)\u{201D}."))
        }
        record(client: client, request: request, outcome: outcome)
        switch outcome {
        case .success(let value): return AgentProtocol.Response(id: request.id, result: value)
        case .failure(let failure): return AgentProtocol.Response(id: request.id, error: failure)
        }
    }

    private func authorize(_ client: AgentClient, for needed: AgentProtocol.Tier) async
        -> Result<Void, AgentProtocol.Failure> {
        if let granted = settings.approvals.first(where: { $0.name == client.name }), granted.tier >= needed {
            return .success(())
        }
        if let until = refusedUntil[client.name], until > Date() {
            return .failure(.denied("\u{201C}\(client.name)\u{201D} was refused access recently."))
        }
        let existing = settings.approvals.first { $0.name == client.name }
        let where_ = client.path.isEmpty ? "" : "\n\n\(client.path)"
        let choice: Int?
        let grants: [AgentProtocol.Tier]
        if existing != nil {
            choice = await ask("\u{201C}\(client.name)\u{201D} wants to open sessions",
                               "It can already read your hosts. Opening sessions lets it connect you to "
                               + "hosts and open groups; it still can't type into them or arm MultiExec."
                               + where_,
                               choices: ["Allow", "Don\u{2019}t Allow"])
            grants = [.open]
        } else {
            choice = await ask("Allow \u{201C}\(client.name)\u{201D} to use Portside?",
                               "A program on this Mac is asking to use Portside through Agent Access. "
                               + "Read lets it list your hosts, groups and tabs. Open also lets it connect "
                               + "to hosts — protected hosts and large selections still ask you first."
                               + where_,
                               choices: ["Allow Read and Open", "Allow Read Only", "Don\u{2019}t Allow"])
            grants = [.open, .read]
        }
        guard let choice, choice < grants.count else {
            refusedUntil[client.name] = Date().addingTimeInterval(600)
            return .failure(choice == nil ? .timedOut : .declined)
        }
        let tier = grants[choice]
        settings.approvals.removeAll { $0.name == client.name }
        settings.approvals.append(Approval(name: client.name, path: client.path, tier: tier, approvedAt: Date()))
        saveSettings()
        // "Read only" answers a request that needed more with a no — for this
        // request; the approval itself stands.
        return tier >= needed ? .success(()) : .failure(.denied("\u{201C}\(client.name)\u{201D} is approved to read only."))
    }

    private func run(_ method: AgentProtocol.Method, _ params: AgentProtocol.Params,
                     client: AgentClient) async -> Result<JSONValue, AgentProtocol.Failure> {
        guard let store, let sessions else { return .failure(.denied("Portside isn't ready yet.")) }
        switch method {
        case .status:
            return .success(.object([
                "app": .string("Portside"),
                "version": JSONValue(ReleaseNotes.appVersion),
                "protocol": JSONValue(AgentProtocol.version),
                "client": .string(client.name),
                "tier": .string(settings.approvals.first { $0.name == client.name }?.tier.label ?? "none"),
                "hosts": JSONValue(store.allEntries.count),
                "tabs": JSONValue(sessions.tabs.filter { !$0.isStartPage }.count),
                "connectCap": JSONValue(settings.connectCap),
            ]))

        case .hosts:
            let text = params.query?.trimmingCharacters(in: .whitespaces) ?? ""
            let query = HostQuery(text)
            if !query.invalidPatterns.isEmpty {
                return .failure(.badRequest("Invalid pattern: \(query.invalidPatterns.joined(separator: ", "))"))
            }
            let names = profileNames(store)
            let rows = store.allEntries
                .filter { text.isEmpty || query.matches($0, profileNames: names) }
                .sorted { ($0.folder, $0.name) < ($1.folder, $1.name) }
                .map { AgentPolicy.hostRow($0, source: store.inventorySource(forEntry: $0.id)?.name) }
            return .success(.array(rows))

        case .groups:
            return .success(.array(store.groups.map { group in
                .object([
                    "id": .string(group.id.uuidString),
                    "name": .string(group.name),
                    "folder": .string(group.folder),
                    "panes": JSONValue(group.paneCount),
                ])
            }))

        case .tabs:
            return .success(.array(tabRows(sessions)))

        case .connect:
            let selection = AgentPolicy.selectHosts(params, from: store.allEntries, profileNames: profileNames(store))
            guard case .success(let hosts) = selection else {
                if case .failure(let failure) = selection { return .failure(failure) }
                return .failure(.badRequest("No selection."))
            }
            let grid = params.layout == "grid"
            if grid, hosts.count < 2 { return .failure(.badRequest("A grid needs at least two hosts.")) }
            if let reason = AgentPolicy.connectConfirmation(for: hosts, cap: settings.connectCap) {
                let list = hosts.prefix(12).map(\.name).joined(separator: ", ")
                    + (hosts.count > 12 ? ", \u{2026}" : "")
                let ok = await ask("\u{201C}\(client.name)\u{201D} wants to connect to \(hosts.count) host\(hosts.count == 1 ? "" : "s")",
                                   "This needs your OK because it includes \(reason).\n\n\(list)",
                                   choices: ["Connect", "Cancel"])
                guard ok == 0 else { return .failure(ok == nil ? .timedOut : .declined) }
            }
            let before = Set(sessions.tabs.map(\.id))
            sessions.connectAll(hosts.map(store.resolved), multiExec: grid, armed: false)
            let opened = sessions.tabs.filter { !before.contains($0.id) }
            agentTabs.formUnion(opened.map(\.id))
            return .success(.object([
                "opened": .array(hosts.map { .string($0.name) }),
                "tabs": .array(opened.map { .string($0.id.uuidString) }),
                "layout": .string(grid ? "grid" : "tabs"),
                "multiExecArmed": .bool(false),
            ]))

        case .openGroup:
            guard let group = findGroup(params, in: store) else {
                return .failure(.notFound("No group by that name or id."))
            }
            let members = group.memberEntryIDs.compactMap { store.entry(id: $0) }
            if let reason = AgentPolicy.connectConfirmation(for: members, cap: settings.connectCap) {
                let ok = await ask("\u{201C}\(client.name)\u{201D} wants to open \u{201C}\(group.name)\u{201D}",
                                   "This needs your OK because it includes \(reason).",
                                   choices: ["Open", "Cancel"])
                guard ok == 0 else { return .failure(ok == nil ? .timedOut : .declined) }
            }
            let before = Set(sessions.tabs.map(\.id))
            let result = sessions.launch(group) { store.entry(id: $0).map(store.resolved) }
            // Groups always open disarmed (see `SessionGroup.layout`).
            agentTabs.formUnion(sessions.tabs.map(\.id).filter { !before.contains($0) })
            return .success(.object([
                "group": .string(group.name),
                "opened": JSONValue(result.opened),
                "missing": JSONValue(result.missing.count),
                "alreadyOpen": .bool(result.wasAlreadyOpen),
            ]))

        case .focus:
            guard let tab = findTab(params, in: sessions) else { return .failure(.notFound("No tab by that id or title.")) }
            sessions.selectedTabID = tab.id
            return .success(.object(["focused": .string(tab.id.uuidString)]))

        case .close:
            guard let tab = findTab(params, in: sessions) else { return .failure(.notFound("No tab by that id or title.")) }
            if !agentTabs.contains(tab.id) {
                let names = tab.leaves.map(\.title).joined(separator: ", ")
                let ok = await ask("\u{201C}\(client.name)\u{201D} wants to close a tab it didn\u{2019}t open",
                                   "Closing ends these sessions: \(names)",
                                   choices: ["Close", "Cancel"])
                guard ok == 0 else { return .failure(ok == nil ? .timedOut : .declined) }
            }
            sessions.closeTab(tab)
            agentTabs.remove(tab.id)
            return .success(.object(["closed": .string(tab.id.uuidString)]))
        }
    }

    private func profileNames(_ store: SessionStore) -> [UUID: String] {
        Dictionary(store.credentialProfiles.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    }

    private func tabRows(_ sessions: SessionManager) -> [JSONValue] {
        sessions.tabs.filter { !$0.isStartPage }.map { tab in
            .object([
                "id": .string(tab.id.uuidString),
                "title": JSONValue(tab.customTitle ?? tab.activeLeaf?.title),
                "selected": .bool(tab.id == sessions.selectedTab?.id),
                "multiExecArmed": .bool(tab.broadcastArmed),
                "openedByAgent": .bool(agentTabs.contains(tab.id)),
                "panes": .array(tab.leaves.map { leaf in
                    .object([
                        "id": .string(leaf.id.uuidString),
                        "title": .string(leaf.title),
                        "host": JSONValue(leaf.entry?.name),
                        "hostID": JSONValue(leaf.entry?.id.uuidString),
                        "running": .bool(leaf.isRunning),
                        "connected": .bool(leaf.didConnect),
                    ])
                }),
            ])
        }
    }

    private func findGroup(_ params: AgentProtocol.Params, in store: SessionStore) -> SessionGroup? {
        if let id = params.ids?.first.flatMap(UUID.init(uuidString:)) { return store.group(id: id) }
        guard let name = params.name ?? params.query else { return nil }
        return store.groups.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    private func findTab(_ params: AgentProtocol.Params, in sessions: SessionManager) -> Tab? {
        let tabs = sessions.tabs.filter { !$0.isStartPage }
        if let id = params.ids?.first.flatMap(UUID.init(uuidString:)) { return tabs.first { $0.id == id } }
        guard let name = params.name else { return nil }
        return tabs.first { ($0.customTitle ?? $0.activeLeaf?.title ?? "").caseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: - Audit

    private func record(client: AgentClient, request: AgentProtocol.Request,
                        outcome: Result<JSONValue, AgentProtocol.Failure>) {
        let detail = [request.params.query, request.params.name, request.params.ids?.joined(separator: ","),
                      request.params.layout].compactMap { $0 }.joined(separator: " ")
        let result: String
        switch outcome {
        case .success: result = "ok"
        case .failure(let f): result = f.code
        }
        let entry = Activity(date: Date(), client: client.name, method: request.method, detail: detail, outcome: result)
        activity.insert(entry, at: 0)
        if activity.count > 200 { activity.removeLast(activity.count - 200) }

        guard let url = logURL else { return }
        let line: [String: String] = [
            "time": ISO8601DateFormatter().string(from: entry.date),
            "client": client.name, "path": client.path, "pid": String(client.pid),
            "method": request.method, "params": detail, "outcome": result,
        ]
        guard var data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}
