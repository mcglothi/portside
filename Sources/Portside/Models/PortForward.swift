import Foundation

enum ForwardKind: String, Codable, CaseIterable, Identifiable {
    case local, remote, dynamic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .local: return "Local"
        case .remote: return "Remote"
        case .dynamic: return "Dynamic (SOCKS)"
        }
    }

    var flag: String {
        switch self {
        case .local: return "-L"
        case .remote: return "-R"
        case .dynamic: return "-D"
        }
    }

    var explanation: String {
        switch self {
        case .local:
            return "A port on this Mac tunnels to a host reachable from the SSH server."
        case .remote:
            return "A port on the SSH server tunnels back to a host reachable from this Mac."
        case .dynamic:
            return "A SOCKS5 proxy on this Mac routes traffic through the SSH server."
        }
    }
}

/// A saved tunnel definition. The transport host is a session from the
/// library (referenced by id), so tunnels inherit its user, key, alias,
/// and saved password.
struct PortForward: Identifiable, Hashable {
    var id = UUID()
    var name = ""
    var kind: ForwardKind = .local
    var hostID: UUID?
    var bindAddress = ""             // "" = ssh default (loopback)
    var listenPort = 8080
    var destinationHost = "localhost"
    var destinationPort = 80
    var autoStart = false            // start when Portside launches

    /// The argument to -L/-R/-D, e.g. "8080:localhost:80" or "1080".
    var spec: String {
        let bind = bindAddress.isEmpty ? "" : bindAddress + ":"
        switch kind {
        case .local, .remote:
            return "\(bind)\(listenPort):\(destinationHost):\(destinationPort)"
        case .dynamic:
            return "\(bind)\(listenPort)"
        }
    }

    /// Human-readable route, shown under the tunnel's name.
    var routeText: String {
        let bind = bindAddress.isEmpty ? "localhost" : bindAddress
        switch kind {
        case .local:
            return "\(bind):\(listenPort) → \(destinationHost):\(destinationPort)"
        case .remote:
            return "remote:\(listenPort) → \(destinationHost):\(destinationPort)"
        case .dynamic:
            return "SOCKS5 proxy on \(bind):\(listenPort)"
        }
    }

    var displayName: String {
        name.isEmpty ? routeText : name
    }
}

// decodeIfPresent keeps older library files loading when fields are added,
// matching the SessionEntry pattern.
extension PortForward: Codable {
    enum CodingKeys: String, CodingKey {
        case id, name, kind, hostID, bindAddress, listenPort
        case destinationHost, destinationPort, autoStart
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try c.decodeIfPresent(ForwardKind.self, forKey: .kind) ?? .local
        hostID = try c.decodeIfPresent(UUID.self, forKey: .hostID)
        bindAddress = try c.decodeIfPresent(String.self, forKey: .bindAddress) ?? ""
        listenPort = try c.decodeIfPresent(Int.self, forKey: .listenPort) ?? 8080
        destinationHost = try c.decodeIfPresent(String.self, forKey: .destinationHost) ?? "localhost"
        destinationPort = try c.decodeIfPresent(Int.self, forKey: .destinationPort) ?? 80
        autoStart = try c.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
    }
}
