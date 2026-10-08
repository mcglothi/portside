import Darwin
import Foundation

/// Who is on the other end of an agent connection.
struct AgentClient: Equatable, Sendable {
    /// The process that opened the socket — usually the CLI itself.
    var pid: pid_t
    /// The first ancestor that isn't a shell or the CLI: `claude`, `codex`,
    /// `Terminal`. What the approval prompt names, and what approval is keyed
    /// by.
    var name: String
    /// That ancestor's executable, shown beside the name so a person can tell
    /// two `claude`s apart.
    var path: String
}

/// The agent socket: a Unix domain socket beside the library, mode 0600, one
/// JSON request per connection.
///
/// It only exists while Agent Access is on. The file mode keeps other users
/// out; *which of this user's programs* is asking is answered by the peer's
/// process, and whether that program may is the user's call, made in the app
/// (see `AgentController`). Nothing listens on the network.
final class AgentServer: @unchecked Sendable {
    typealias Handler = @Sendable (AgentProtocol.Request, AgentClient) async -> AgentProtocol.Response

    let socketPath: String
    private let handler: Handler
    private let lock = NSLock()
    private var listenFD: Int32 = -1

    init(socketPath: String, handler: @escaping Handler) {
        self.socketPath = socketPath
        self.handler = handler
    }

    /// Where the socket lives for a library directory. A Unix socket path is
    /// capped at 104 bytes, which a deep `PORTSIDE_LIBRARY_DIR` can exceed, so
    /// a long one moves to the per-user temp directory under a name derived
    /// from the library path — the CLI computes the same thing.
    static func socketPath(libraryDirectory: URL) -> String {
        let preferred = libraryDirectory.appendingPathComponent("agent.sock").path
        if preferred.utf8.count < 100 { return preferred }
        var hash: UInt64 = 0xcbf29ce484222325 // FNV-1a, stable across launches
        for byte in libraryDirectory.path.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("portside-\(String(hash, radix: 16)).sock")
    }

    var isRunning: Bool { lock.withLock { listenFD >= 0 } }

    func start() throws {
        guard !isRunning else { return }
        try FileManager.default.createDirectory(
            atPath: (socketPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        // A leftover socket from a crash would make bind fail. Only a socket
        // is removed — never whatever else might have that name.
        var st = stat()
        if lstat(socketPath, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK { unlink(socketPath) }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let bytes = Array(socketPath.utf8.prefix(raw.count - 1))
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        // Created 0600 from the first instant rather than chmod'ed after, so
        // there's no window where another user could connect.
        let oldMask = umask(0o177)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(oldMask)
        guard bound == 0, listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        lock.withLock { listenFD = fd }
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "Portside agent socket"
        thread.start()
    }

    func stop() {
        let fd = lock.withLock { () -> Int32 in
            let fd = listenFD
            listenFD = -1
            return fd
        }
        guard fd >= 0 else { return }
        // shutdown wakes the blocked accept; close alone may not.
        shutdown(fd, SHUT_RDWR)
        close(fd)
        unlink(socketPath)
    }

    deinit { stop() }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let conn = accept(fd, nil, nil)
            if conn < 0 {
                if errno == EINTR { continue }
                return // stopped
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.serve(conn)
            }
        }
    }

    private func serve(_ conn: Int32) {
        defer { close(conn) }
        // Belt and braces on top of the 0600 mode: only this user's processes.
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(conn, &uid, &gid) == 0, uid == getuid() else { return }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(conn, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let client = Self.identify(peerPID(conn))
        let response: AgentProtocol.Response
        if let line = readLine(conn) {
            if let request = try? JSONDecoder().decode(AgentProtocol.Request.self, from: line) {
                response = runBlocking { await self.handler(request, client) }
            } else {
                response = AgentProtocol.Response(error: .badRequest("Not a JSON request."))
            }
        } else {
            response = AgentProtocol.Response(error: .badRequest("No request, or a request over 64 KB."))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(response) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = write(conn, raw.baseAddress! + sent, raw.count - sent)
                if n <= 0 { break }
                sent += n
            }
        }
    }

    /// One request per connection; a confirmation in the app can take a
    /// while, and this thread is the connection's own, so waiting here is fine.
    private func runBlocking(_ work: @escaping @Sendable () async -> AgentProtocol.Response) -> AgentProtocol.Response {
        let box = ResponseBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await work()
            done.signal()
        }
        done.wait()
        return box.value ?? AgentProtocol.Response(error: .badRequest("No response."))
    }

    private final class ResponseBox: @unchecked Sendable { var value: AgentProtocol.Response? }

    private func readLine(_ conn: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 65_536 {
            let n = read(conn, &buffer, buffer.count)
            if n <= 0 { break }
            if let newline = buffer[0..<n].firstIndex(of: 0x0A) {
                data.append(contentsOf: buffer[0..<newline])
                return data
            }
            data.append(contentsOf: buffer[0..<n])
        }
        return data.isEmpty || data.count >= 65_536 ? nil : data
    }

    private func peerPID(_ conn: Int32) -> pid_t {
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        return getsockopt(conn, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) == 0 ? pid : 0
    }

    // MARK: - Naming the caller

    /// Wrappers that say nothing about *who* is asking: shells, and the CLI.
    private static let passThrough: Set<String> = [
        "sh", "bash", "zsh", "fish", "dash", "tcsh", "csh", "ksh", "env", "login", "xargs", "timeout",
        "portside", "portside-cli",
    ]

    /// Walks up from the connecting process to the first one that isn't a
    /// shell or the CLI. Uses the name the process was *started as*
    /// (`p_comm`), not its resolved executable: Claude Code's real binary
    /// lives in a versioned npm path that changes on every update, while it
    /// was started as `claude`.
    static func identify(_ pid: pid_t) -> AgentClient {
        var current = pid
        var fallback = AgentClient(pid: pid, name: "unknown", path: "")
        for _ in 0..<12 {
            guard current > 1, let info = processInfo(current) else { break }
            let client = AgentClient(pid: pid, name: info.name, path: executablePath(current))
            if fallback.name == "unknown" { fallback = client }
            if !passThrough.contains(info.name.lowercased()) { return client }
            current = info.parent
        }
        return fallback
    }

    private static func processInfo(_ pid: pid_t) -> (name: String, parent: pid_t)? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let name = withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        // Claude Code's binary is `claude.exe` inside its npm package; people
        // know it as `claude`.
        let shown = name.hasSuffix(".exe") ? String(name.dropLast(4)) : name
        return (shown.isEmpty ? "unknown" : shown, info.kp_eproc.e_ppid)
    }

    private static func executablePath(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return "" }
        return String(cString: buffer)
    }
}
