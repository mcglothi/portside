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
    var execCommand: String? {
        let container = name.trimmingCharacters(in: .whitespaces)
        guard !container.isEmpty else { return nil }
        var parts = [engine.rawValue, "exec", "-it"]
        let u = user.trimmingCharacters(in: .whitespaces)
        if !u.isEmpty { parts += ["-u", u] }
        parts.append(container)
        parts.append(shell.isEmpty ? "sh" : shell)
        return parts.joined(separator: " ")
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

    /// `kubectl [--context c] [-n ns] exec -it <pod> [-c container] -- <shell>`.
    var execCommand: String? {
        let pod = pod.trimmingCharacters(in: .whitespaces)
        guard !pod.isEmpty else { return nil }
        var parts = ["kubectl"]
        let ctx = context.trimmingCharacters(in: .whitespaces)
        if !ctx.isEmpty { parts += ["--context", ctx] }
        let ns = namespace.trimmingCharacters(in: .whitespaces)
        if !ns.isEmpty { parts += ["-n", ns] }
        parts += ["exec", "-it", pod]
        let c = container.trimmingCharacters(in: .whitespaces)
        if !c.isEmpty { parts += ["-c", c] }
        parts += ["--", shell.isEmpty ? "sh" : shell]
        return parts.joined(separator: " ")
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
            sshCommand += ["-i", "'\((path as NSString).expandingTildeInPath)'"]
        }
        let usingAlias = !(sshAlias?.isEmpty ?? true)
        if !usingAlias, let port {
            sshCommand += ["-p", String(port)]
        }
        if sshCommand.count > 1 {
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
        case kind, container, kubernetes, serial, telnet, preferMosh
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
}

struct FolderNode: Identifiable {
    var id: String { path }
    let path: String
    let name: String
    var subfolders: [FolderNode]
    var entries: [SessionEntry]
}

enum FolderTree {
    /// Splits entries into top-level entries and a sorted folder hierarchy.
    /// `explicitFolders` are standalone (possibly empty) folders that should
    /// render even when no session lives in them.
    static func build(
        entries: [SessionEntry],
        explicitFolders: [String] = []
    ) -> (root: [SessionEntry], folders: [FolderNode]) {
        let root = entries.filter { $0.folder.isEmpty }.sorted(by: byName)

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

        var directEntries: [String: [SessionEntry]] = [:]
        for entry in entries where !entry.folder.isEmpty {
            directEntries[entry.folder, default: []].append(entry)
        }

        return (root, childNodes(parent: "", paths: paths, directEntries: directEntries))
    }

    private static func childNodes(
        parent: String,
        paths: Set<String>,
        directEntries: [String: [SessionEntry]]
    ) -> [FolderNode] {
        let prefix = parent.isEmpty ? "" : parent + "/"
        let depth = parent.isEmpty ? 1 : parent.split(separator: "/").count + 1
        let children = paths.filter { $0.hasPrefix(prefix) && $0.split(separator: "/").count == depth }
        let sorted = children.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return sorted.map { path in
            FolderNode(
                path: path,
                name: String(path.split(separator: "/").last ?? Substring(path)),
                subfolders: childNodes(parent: path, paths: paths, directEntries: directEntries),
                entries: (directEntries[path] ?? []).sorted(by: byName)
            )
        }
    }

    private static func byName(_ a: SessionEntry, _ b: SessionEntry) -> Bool {
        a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
}
