import Foundation

enum HostEnvironment: String, Codable, CaseIterable, Identifiable {
    case none, prod, staging, dev, personal

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "None"
        case .prod: return "Prod"
        case .staging: return "Staging"
        case .dev: return "Dev"
        case .personal: return "Personal"
        }
    }
}

/// What a session actually drops you into. Host/container/kubernetes share
/// the same transport (an SSH host, or this Mac for local containers/pods);
/// only the shell at the far end differs. Serial and telnet have direct
/// transports — no child process at all.
enum SessionKind: String, Codable, CaseIterable, Identifiable {
    case host, container, kubernetes, serial, telnet

    var id: String { rawValue }

    var label: String {
        switch self {
        case .host: return "SSH Host"
        case .container: return "Container"
        case .kubernetes: return "Kubernetes"
        case .serial: return "Serial Port"
        case .telnet: return "Telnet"
        }
    }

    var icon: String {
        switch self {
        case .host: return "server.rack"
        case .container: return "shippingbox"
        case .kubernetes: return "circle.hexagongrid"
        case .serial: return "cable.connector"
        case .telnet: return "network"
        }
    }
}

/// A docker/podman/nerdctl container to exec into.
struct ContainerTarget: Codable, Hashable {
    enum Engine: String, Codable, CaseIterable, Identifiable {
        case docker, podman, nerdctl
        var id: String { rawValue }
        var label: String { rawValue }
    }

    var engine: Engine = .docker
    var name = ""
    var shell = "sh"       // Alpine-safe default
    var user = ""          // optional -u

    /// `docker exec -it [-u user] <name> <shell>`; nil until a name is set.
    /// Quoted at this boundary with `ShellQuoting`: this string is later typed
    /// into a live shell (`SessionManager.postConnect`), and every field here
    /// can come from an imported, untrusted library.
    var execCommand: String? {
        let container = name.trimmingCharacters(in: .whitespaces).strippingControlCharacters
        guard !container.isEmpty, !container.looksLikeShellOption else { return nil }
        var parts = [engine.rawValue, "exec", "-it"]
        let u = user.trimmingCharacters(in: .whitespaces).strippingControlCharacters
        if !u.isEmpty { parts += ["-u", u] }
        parts.append(container)
        let sh = shell.strippingControlCharacters
        parts.append(sh.isEmpty ? "sh" : sh)
        return ShellQuoting.command(parts)
    }
}

/// A Kubernetes pod to exec into. `context` selects the cluster (NKP, GKE, …)
/// so the same host/kubeconfig can reach many clusters.
struct KubernetesTarget: Codable, Hashable {
    var context = ""
    var namespace = ""
    var pod = ""
    var container = ""     // optional -c for multi-container pods
    var shell = "sh"

    /// `kubectl [--context=c] [--namespace=ns] exec -it <pod> [--container=c] -- <shell>`.
    /// Quoted at this boundary with `ShellQuoting`, same as
    /// `ContainerTarget.execCommand` and `ContainerLister.enumerationArguments`
    /// — `--flag=value` rather than `--flag value` so a value beginning with a
    /// dash can't be read by kubectl as another flag, and `pod` is checked
    /// separately since it lands in a positional slot no `=` form protects.
    var execCommand: String? {
        let pod = pod.trimmingCharacters(in: .whitespaces).strippingControlCharacters
        guard !pod.isEmpty, !pod.looksLikeShellOption else { return nil }
        var parts = ["kubectl"]
        let ctx = context.trimmingCharacters(in: .whitespaces).strippingControlCharacters
        if !ctx.isEmpty { parts.append("--context=\(ctx)") }
        let ns = namespace.trimmingCharacters(in: .whitespaces).strippingControlCharacters
        if !ns.isEmpty { parts.append("--namespace=\(ns)") }
        parts += ["exec", "-it", pod]
        let c = container.trimmingCharacters(in: .whitespaces).strippingControlCharacters
        if !c.isEmpty { parts.append("--container=\(c)") }
        let sh = shell.strippingControlCharacters
        parts += ["--", sh.isEmpty ? "sh" : sh]
        return ShellQuoting.command(parts)
    }
}

/// A local serial device (USB adapter, console cable) and its line settings.
/// The classic switch-stack default is 9600 8N1; modern USB consoles mostly
/// run 115200, so that's the starting value.
struct SerialTarget: Codable, Hashable {
    enum Parity: String, Codable, CaseIterable, Identifiable {
        case none, even, odd
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        /// The letter in the "8N1"-style summary.
        var letter: String {
            switch self {
            case .none: return "N"
            case .even: return "E"
            case .odd: return "O"
            }
        }
    }

    enum FlowControl: String, Codable, CaseIterable, Identifiable {
        case none, rtsCts, xonXoff
        var id: String { rawValue }
        var label: String {
            switch self {
            case .none: return "None"
            case .rtsCts: return "Hardware (RTS/CTS)"
            case .xonXoff: return "Software (XON/XOFF)"
            }
        }
    }

    var devicePath = ""
    var baudRate = 115200
    var dataBits = 8            // 7 or 8
    var parity: Parity = .none
    var stopBits = 1            // 1 or 2
    var flowControl: FlowControl = .none

    static let baudRates = [300, 1200, 2400, 4800, 9600, 19200, 38400,
                            57600, 115200, 230400, 460800, 921600]

    /// "115200 8N1" — the shorthand every console jockey reads at a glance.
    var summary: String {
        "\(baudRate) \(dataBits)\(parity.letter)\(stopBits)"
    }

    /// "cu.usbserial-0001" — the device without the /dev/ noise.
    var deviceName: String {
        (devicePath as NSString).lastPathComponent
    }
}

/// An unencrypted TCP terminal endpoint. Telnet defaults to its conventional
/// port while remaining explicit in saved sessions and log paths.
struct TelnetTarget: Codable, Hashable {
    var host = ""
    var port = 23

    /// Network.framework requires a non-zero 16-bit port. Treat a malformed
    /// value in an older or hand-edited library as the conventional default.
    var resolvedPort: UInt16 {
        guard (1...65_535).contains(port) else { return 23 }
        return UInt16(port)
    }
}

struct SessionEntry: Identifiable, Hashable {
    enum Source: String, Codable {
        case manual, sshConfig, mobaxterm
    }

    var id = UUID()
    var name: String
    var folder: String = ""          // "" = top level; nested paths use "/", e.g. "prod/web"
    var hostname: String = ""
    var user: String?
    var port: Int?
    var sshAlias: String?            // when set, connect via `ssh <alias>` so ~/.ssh/config rules apply
    var identityFile: String?        // private key path; passed as `ssh -i`
    var savePassword = false         // password stored in the Keychain under this id
    var source: Source = .manual
    var environment: HostEnvironment = .none
    var isProtected = false          // excluded from MultiExec unless explicitly confirmed
    var runOnConnect: String?        // command sent to the shell shortly after connecting
    var kind: SessionKind = .host
    var container: ContainerTarget?  // set when kind == .container
    var kubernetes: KubernetesTarget?// set when kind == .kubernetes
    var serial: SerialTarget?        // set when kind == .serial
    var telnet: TelnetTarget?        // set when kind == .telnet
    var preferMosh = false           // connect with mosh instead of ssh (hosts only)
    /// A shared identity this host defers to (username/key/password) — see
    /// `CredentialProfile`. When set, the profile's fields win over this
    /// entry's own `user`/`identityFile` and Keychain password, so rotating
    /// the profile updates every host using it without editing each one.
    var credentialProfileID: UUID?
    /// Pinned to the "Favorites" section of the welcome/start page.
    var isFavorite = false

    var icon: String { kind.icon }

    /// Container/pod sessions with no SSH host run on this Mac. (Serial is
    /// local too, but bridges a device fd instead of spawning a shell —
    /// SessionManager branches on the kind before consulting this.)
    var usesLocalTransport: Bool {
        (kind == .container || kind == .kubernetes)
            && hostname.isEmpty && (sshAlias?.isEmpty ?? true)
    }

    /// The command to send once the transport shell is up: the container/pod
    /// exec for those kinds, or the host's run-on-connect string. Direct
    /// terminal transports reuse it (handy for waking a console with a newline).
    var postConnectCommand: String? {
        switch kind {
        case .host, .serial, .telnet:
            let command = runOnConnect?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (command?.isEmpty ?? true) ? nil : command
        case .container:
            return container?.execCommand
        case .kubernetes:
            return kubernetes?.execCommand
        }
    }

    /// The remote file browser only makes sense for a plain SSH host — and
    /// not mosh: sftp rides the ssh ControlMaster socket, which a mosh
    /// session (UDP after bootstrap) never opens.
    var supportsFileBrowser: Bool { kind == .host && !preferMosh }

    var subtitle: String {
        switch kind {
        case .host:
            let userPart = user.map { "\($0)@" } ?? ""
            let portPart = port.map { ":\($0)" } ?? ""
            let target = hostname.isEmpty ? (sshAlias ?? "") : hostname
            return userPart + target + portPart
        case .container:
            let engine = container?.engine.rawValue ?? "docker"
            let name = container?.name ?? ""
            return "\(engine): \(name)\(transportSuffix)"
        case .kubernetes:
            let ns = kubernetes?.namespace ?? ""
            let pod = kubernetes?.pod ?? ""
            let nsPart = ns.isEmpty ? "" : "\(ns)/"
            return "k8s: \(nsPart)\(pod)\(transportSuffix)"
        case .serial:
            guard let serial, !serial.devicePath.isEmpty else { return "no device" }
            return "\(serial.deviceName) · \(serial.summary)"
        case .telnet:
            guard let telnet, !telnet.host.isEmpty else { return "no host" }
            return "\(telnet.host):\(telnet.port)"
        }
    }

    private var transportSuffix: String {
        if usesLocalTransport { return " · local" }
        let host = hostname.isEmpty ? (sshAlias ?? "") : hostname
        return host.isEmpty ? "" : " · via \(host)"
    }

    private var identityArgs: [String] {
        guard let path = identityFile, !path.isEmpty else { return [] }
        return ["-i", (path as NSString).expandingTildeInPath]
    }

    var sshArgs: [String] {
        if let alias = sshAlias, !alias.isEmpty {
            return identityArgs + [alias]
        }
        var args = identityArgs
        if let port {
            args += ["-p", String(port)]
        }
        args.append(user.map { "\($0)@\(hostname)" } ?? hostname)
        return args
    }

    /// mosh bootstraps over its own ssh, so identity/port ride inside --ssh
    /// (which mosh word-splits — hence the quoting around the key path).
    /// Aliases resolve through ~/.ssh/config exactly like plain ssh.
    var moshArgs: [String] {
        var args: [String] = []
        var sshCommand = ["ssh"]
        if let path = identityFile, !path.isEmpty {
            sshCommand += ["-i", ShellQuoting.quote((path as NSString).expandingTildeInPath)]
        }
        let usingAlias = !(sshAlias?.isEmpty ?? true)
        if !usingAlias, let port {
            sshCommand += ["-p", String(port)]
        }
        if sshCommand.count > 1 {
            // mosh word-splits --ssh's value itself (shellwords), so the
            // pieces above are pre-quoted rather than passed through
            // ShellQuoting.command, which would double-quote "ssh"/"-i"/"-p".
            args.append("--ssh=\(sshCommand.joined(separator: " "))")
        }
        if usingAlias {
            args.append(sshAlias!)
        } else {
            args.append(user.map { "\($0)@\(hostname)" } ?? hostname)
        }
        return args
    }

    /// Same target as `sshArgs`, but sftp spells the port flag -P.
    var sftpTargetArgs: [String] {
        if let alias = sshAlias, !alias.isEmpty {
            return identityArgs + [alias]
        }
        var args = identityArgs
        if let port {
            args += ["-P", String(port)]
        }
        args.append(user.map { "\($0)@\(hostname)" } ?? hostname)
        return args
    }
}

// Codable lives in an extension so the memberwise initializer survives;
// decodeIfPresent keeps older library files loading when fields are added.
extension SessionEntry: Codable {
    enum CodingKeys: String, CodingKey {
        case id, name, folder, hostname, user, port, sshAlias, identityFile, savePassword
        case source, environment, isProtected, runOnConnect
        case kind, container, kubernetes, serial, telnet, preferMosh, credentialProfileID
        case isFavorite
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        folder = try c.decodeIfPresent(String.self, forKey: .folder) ?? ""
        hostname = try c.decodeIfPresent(String.self, forKey: .hostname) ?? ""
        user = try c.decodeIfPresent(String.self, forKey: .user)
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        sshAlias = try c.decodeIfPresent(String.self, forKey: .sshAlias)
        identityFile = try c.decodeIfPresent(String.self, forKey: .identityFile)
        savePassword = try c.decodeIfPresent(Bool.self, forKey: .savePassword) ?? false
        source = try c.decodeIfPresent(Source.self, forKey: .source) ?? .manual
        environment = try c.decodeIfPresent(HostEnvironment.self, forKey: .environment) ?? .none
        isProtected = try c.decodeIfPresent(Bool.self, forKey: .isProtected) ?? false
        runOnConnect = try c.decodeIfPresent(String.self, forKey: .runOnConnect)
        kind = try c.decodeIfPresent(SessionKind.self, forKey: .kind) ?? .host
        container = try c.decodeIfPresent(ContainerTarget.self, forKey: .container)
        kubernetes = try c.decodeIfPresent(KubernetesTarget.self, forKey: .kubernetes)
        serial = try c.decodeIfPresent(SerialTarget.self, forKey: .serial)
        telnet = try c.decodeIfPresent(TelnetTarget.self, forKey: .telnet)
        preferMosh = try c.decodeIfPresent(Bool.self, forKey: .preferMosh) ?? false
        credentialProfileID = try c.decodeIfPresent(UUID.self, forKey: .credentialProfileID)
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
    }
}

/// App-wide fallback credentials applied to sessions that don't set their own.
struct ConnectionDefaults: Codable, Equatable {
    var user: String?
    var identityFile: String?
    /// Whether a freshly created session starts with "Save password in
    /// Keychain" already checked. There's no secret to default in (unlike
    /// `user`/`identityFile`, this can't be applied retroactively at connect
    /// time) — it only seeds the toggle when a new session is created.
    var defaultSavePassword: Bool?
    /// Passes `-o StrictHostKeyChecking=accept-new` to ssh: a first-time
    /// connection to an unknown host is trusted automatically (no more typing
    /// "yes"), but ssh still hard-fails if an *already-known* host's key ever
    /// changes — the actual MITM protection stays intact. Applies to plain
    /// SSH connections only (not mosh's bootstrap ssh).
    var autoAcceptNewHostKeys: Bool?
    /// Application bundle path that remote files opened from the SFTP browser
    /// are edited in. nil defers to whatever macOS associates with the file
    /// type — frequently nothing useful for `.conf`/`.yml`/extensionless
    /// files, which is why this is worth setting once.
    var remoteEditorPath: String?

    /// How many hosts a MultiExec file copy uploads to at once.
    ///
    /// Optional like everything else here on purpose: a missing key has to
    /// decode, not throw, or one old record fails the whole library load.
    ///
    /// Serial (1) is a legitimate choice — hosts then finish one at a time, so
    /// the earliest is usable soonest — but it lets a single unresponsive host
    /// block every host behind it, which is why the default is not 1.
    var transferConcurrency: Int?

    /// Clamped to something a shared uplink can actually sustain. Four is a
    /// deliberate middle: enough that one stalled host cannot hold up the
    /// group, few enough that a broadcast to twenty boxes does not open twenty
    /// ssh processes against one upstream.
    var resolvedTransferConcurrency: Int {
        min(max(transferConcurrency ?? 4, 1), 8)
    }

    var remoteEditorURL: URL? {
        guard let path = remoteEditorPath, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }
}

/// A reusable identity (username + SSH key and/or password) a host can defer
/// to instead of holding its own credentials — see `SessionEntry.
/// credentialProfileID`. The password itself lives in the Keychain, keyed by
/// `id` (`CredentialStore.profilePassword`), never in the JSON library.
struct CredentialProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var user: String?
    var identityFile: String?
}

extension String {
    /// Whether two profile names refer to the same credential for import
    /// purposes. Case and surrounding whitespace differ freely between a
    /// profile typed on one Mac and the same one typed on another; "Ops " and
    /// "ops" are not two different credentials to anyone but a byte
    /// comparison.
    func matchesProfileName(_ other: String) -> Bool {
        trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(
            other.trimmingCharacters(in: .whitespaces)
        ) == .orderedSame
    }
}

/// One entry in the "jump back in" history: which host, connected when.
struct RecentConnection: Codable, Hashable {
    var entryID: UUID
    var date: Date
}

struct Macro: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var text: String
    var sendReturn = true
    /// Pinned to the MultiExec macro bar. With more macros than fit across the
    /// window the bar is unusable, so it shows favourites when there are any.
    var isFavorite = false
}

// Tolerant Codable, and not optional politeness: Swift's *synthesized* decoder
// ignores property defaults and throws `keyNotFound` on a missing key, while
// `SessionStore.Document.macros` is non-optional. So adding a field to this
// struct without this would make one old macro fail the entire library load --
// the same shape as the 0.16 audit's migration P0. Verified by removing this
// decoder and watching two decode tests fail.
extension Macro {
    enum CodingKeys: String, CodingKey {
        case id, name, text, sendReturn, isFavorite
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        sendReturn = try c.decodeIfPresent(Bool.self, forKey: .sendReturn) ?? true
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
    }
}

struct FolderNode: Identifiable {
    var id: String { path }
    let path: String
    let name: String
    var subfolders: [FolderNode]
    var entries: [SessionEntry]
    /// Saved groups filed here, shown above the individual hosts — a group is
    /// a way to open several of them at once, so it reads as the heading for
    /// the folder rather than one more item in it.
    var groups: [SessionGroup] = []
}

/// What the sidebar renders: loose hosts and groups at the top level, then the
/// folder hierarchy. A named type rather than a tuple because it is threaded
/// through the outline view, its coordinator, the signature used to decide
/// whether to rebuild, and keyboard navigation — and it grew a third member
/// the moment groups arrived.
struct SidebarTree {
    var root: [SessionEntry] = []
    var rootGroups: [SessionGroup] = []
    var folders: [FolderNode] = []
}

enum FolderTree {
    /// Splits entries into top-level entries and a sorted folder hierarchy.
    /// `explicitFolders` are standalone (possibly empty) folders that should
    /// render even when no session lives in them.
    static func build(
        entries: [SessionEntry],
        explicitFolders: [String] = [],
        groups: [SessionGroup] = []
    ) -> SidebarTree {
        let root = entries.filter { $0.folder.isEmpty }.sorted(by: byName)
        let rootGroups = groups.filter { $0.folder.isEmpty }.sorted(by: byGroupName)

        // Every folder path, expanded so each ancestor exists as a node too.
        var paths = Set<String>()
        func addWithAncestors(_ path: String) {
            var prefix = ""
            for part in path.split(separator: "/") {
                prefix = prefix.isEmpty ? String(part) : prefix + "/" + part
                paths.insert(prefix)
            }
        }
        for entry in entries where !entry.folder.isEmpty { addWithAncestors(entry.folder) }
        for folder in explicitFolders { addWithAncestors(folder) }
        // A group keeps its folder alive even when every host has moved out,
        // or the group would vanish from the sidebar while still existing.
        for group in groups where !group.folder.isEmpty { addWithAncestors(group.folder) }

        var directEntries: [String: [SessionEntry]] = [:]
        for entry in entries where !entry.folder.isEmpty {
            directEntries[entry.folder, default: []].append(entry)
        }

        var directGroups: [String: [SessionGroup]] = [:]
        for group in groups where !group.folder.isEmpty {
            directGroups[group.folder, default: []].append(group)
        }

        return SidebarTree(
            root: root, rootGroups: rootGroups,
            folders: childNodes(parent: "", paths: paths,
                       directEntries: directEntries, directGroups: directGroups))
    }

    private static func childNodes(
        parent: String,
        paths: Set<String>,
        directEntries: [String: [SessionEntry]],
        directGroups: [String: [SessionGroup]] = [:]
    ) -> [FolderNode] {
        let prefix = parent.isEmpty ? "" : parent + "/"
        let depth = parent.isEmpty ? 1 : parent.split(separator: "/").count + 1
        let children = paths.filter { $0.hasPrefix(prefix) && $0.split(separator: "/").count == depth }
        let sorted = children.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return sorted.map { path in
            FolderNode(
                path: path,
                name: String(path.split(separator: "/").last ?? Substring(path)),
                subfolders: childNodes(parent: path, paths: paths,
                                      directEntries: directEntries, directGroups: directGroups),
                entries: (directEntries[path] ?? []).sorted(by: byName),
                groups: (directGroups[path] ?? []).sorted(by: byGroupName)
            )
        }
    }

    private static func byName(_ a: SessionEntry, _ b: SessionEntry) -> Bool {
        a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }

    private static func byGroupName(_ a: SessionGroup, _ b: SessionGroup) -> Bool {
        a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
}
