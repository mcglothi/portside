import Darwin
import Foundation

/// The client half of the app's agent socket: find it, send one request,
/// read one reply. Used by both the commands and the MCP server.
enum AgentSocket {
    struct Failure: Error {
        var message: String
        /// Portside isn't running, or Agent Access is off.
        var unavailable = false
    }

    /// Must match `AgentServer.socketPath(libraryDirectory:)` in the app.
    static func path(override: String?) -> String {
        let env = ProcessInfo.processInfo.environment
        if let explicit = override ?? env["PORTSIDE_SOCKET"] { return explicit }
        let directory: String
        if let override = env["PORTSIDE_LIBRARY_DIR"] {
            directory = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true).path
        } else {
            directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Portside").path
        }
        let preferred = (directory as NSString).appendingPathComponent("agent.sock")
        if preferred.utf8.count < 100 { return preferred }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in directory.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return (NSTemporaryDirectory() as NSString).appendingPathComponent("portside-\(String(hash, radix: 16)).sock")
    }

    /// One request, one reply. Blocks for as long as the app takes — a
    /// confirmation can wait up to a couple of minutes for a person.
    static func call(_ method: String, _ params: [String: Any], socket path: String)
        -> Result<[String: Any], Failure> {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(Failure(message: "couldn't create a socket")) }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let bytes = Array(path.utf8.prefix(raw.count - 1))
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            return .failure(Failure(message: "Portside isn't reachable at \(path). Is it running, with "
                                    + "Agent Access on (Settings \u{25B8} Agents)?", unavailable: true))
        }
        var data = (try? JSONSerialization.data(withJSONObject: ["id": 1, "method": method, "params": params]))
            ?? Data()
        data.append(0x0A)
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }

        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            reply.append(contentsOf: buffer[0..<n])
            if buffer[n - 1] == 0x0A { break }
        }
        guard let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
            return .failure(Failure(message: "no reply from Portside"))
        }
        return .success(object)
    }
}
