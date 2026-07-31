import Foundation

struct RemoteFile: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let isDirectory: Bool
    let isSymlink: Bool
    let size: Int
    let dateText: String
    let permissions: String
}

enum SFTPClientError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        }
    }
}

/// Shared SSH connection multiplexing. The interactive terminal session
/// establishes the master connection; sftp operations reuse its socket, so
/// file browsing inherits agent, certs, and ProxyJump with no re-auth.
enum SSHControl {
    /// Keyed by uid rather than a bare shared name: on a multi-user machine
    /// `/tmp` is world-writable, so a fixed path for every account invited
    /// another local user to race directory creation or plant something at
    /// it first. `%C`'s hashed suffix keeps the full ControlPath comfortably
    /// under AF_UNIX's ~104-108 byte socket path limit, which is also why
    /// this stays under `/tmp` rather than a deeper per-user cache directory.
    static let controlDir: String = resolveControlDir()

    static var options: [String] {
        guard verifiedOwnDirectory(controlDir) else {
            // Something already at this path isn't provably ours (wrong
            // owner, wrong mode, or not even a directory) — degrade to an
            // unmultiplexed connection rather than hand OpenSSH a socket
            // path we can't vouch for. A plain ssh/sftp call still works;
            // it just re-authenticates instead of piggybacking.
            NSLog("Portside: %@ failed its ownership/permission check; ControlMaster disabled", controlDir)
            return []
        }
        try? FileManager.default.createDirectory(
            atPath: controlDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlDir)/%C",
            "-o", "ControlPersist=120",
        ]
    }

    /// Reuse an existing master's socket but never become one. Long-lived
    /// helpers (port forwards) use this so other sessions can't end up
    /// piggybacking on a process the user may stop at any time.
    static var passiveOptions: [String] {
        [
            "-o", "ControlMaster=no",
            "-o", "ControlPath=\(controlDir)/%C",
        ]
    }

    private static func resolveControlDir() -> String {
        let base = "/tmp/portside-ssh-\(getuid())"
        if verifiedOwnDirectory(base) { return base }
        // Already claimed by something we can't trust — fall back to a
        // path unique to this process rather than share a compromised one.
        return "/tmp/portside-ssh-\(getuid())-\(ProcessInfo.processInfo.globallyUniqueString)"
    }

    /// True when `path` either doesn't exist yet (safe to create) or already
    /// exists as a real directory — not a symlink — owned by this user, with
    /// no group/other access. `lstat` (not `stat`) so a symlink is judged by
    /// what it *is*, not what it points at.
    static func verifiedOwnDirectory(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return true }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return false }
        guard info.st_uid == getuid() else { return false }
        guard (info.st_mode & 0o777) == 0o700 else { return false }
        return true
    }
}

/// Drives the stock OpenSSH `sftp` binary in batch mode — no SSH library,
/// full ~/.ssh/config compatibility.
struct SFTPClient {
    let entry: SessionEntry

    // MARK: - Operations

    func pwd() async throws -> String {
        let out = try await run(batch: ["pwd"])
        for line in out.components(separatedBy: .newlines) {
            if let range = line.range(of: "Remote working directory: ") {
                return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        throw SFTPClientError.failed("Could not determine remote working directory.")
    }

    func list(_ path: String) async throws -> [RemoteFile] {
        let out = try await run(batch: ["ls -la \(try quote(path))"])
        return Self.parseListing(out)
    }

    func download(remotePath: String, to localURL: URL) async throws {
        let remote = try quote(remotePath)
        let local = try quote(localURL.path)
        _ = try await run(batch: ["get \(remote) \(local)"])
    }

    func upload(localURL: URL, toDirectory remoteDir: String) async throws {
        let directory = try quote(remoteDir)
        let local = try quote(localURL.path)
        _ = try await run(batch: [
            "cd \(directory)",
            "put \(local)",
        ])
    }

    /// Uploads and swaps the result into place atomically: `put` under a
    /// hidden temp name in the same directory, then `rename` over the real
    /// name. OpenSSH's `sftp` client uses the `posix-rename@openssh.com`
    /// extension for `rename` automatically when the server offers it (true
    /// of OpenSSH-to-OpenSSH, the overwhelming case here), which is what
    /// makes overwriting an existing file this way possible at all — plain
    /// SFTP `rename` fails if the destination exists.
    ///
    /// Unlike plain `upload`, this does not preserve the original file's mode
    /// for free (the temp file is created fresh), so `preservingModeFrom`
    /// re-applies it via `chmod` once the swap lands. A `rename` failure
    /// (an SFTP server without the extension, or a genuine permissions
    /// problem) aborts the batch before anything touches the real file —
    /// the temp file is then best-effort removed rather than left behind.
    func uploadReplacing(
        localURL: URL, remotePath: String, preservingModeFrom original: RemoteFile?
    ) async throws {
        let directory = try quote(Self.directory(of: remotePath))
        let finalName = try quote((remotePath as NSString).lastPathComponent)
        let local = try quote(localURL.path)
        let tempName = try quote(".portside-upload-\(UUID().uuidString)")
        do {
            var batch = [
                "cd \(directory)",
                "put \(local) \(tempName)",
                "rename \(tempName) \(finalName)",
            ]
            if let original, let mode = Self.octalMode(fromPermissionString: original.permissions) {
                batch.append("chmod \(String(mode, radix: 8)) \(finalName)")
            }
            _ = try await run(batch: batch)
        } catch {
            _ = try? await run(batch: ["cd \(directory)", "rm \(tempName)"])
            throw error
        }
    }

    /// The current remote state of one file, for comparing against what was
    /// recorded at checkout — nil if it's gone missing entirely.
    func snapshot(of remotePath: String) async throws -> RemoteFile? {
        let name = (remotePath as NSString).lastPathComponent
        let entries = try await list(Self.directory(of: remotePath))
        return entries.first { $0.name == name }
    }

    private static func directory(of remotePath: String) -> String {
        let dir = (remotePath as NSString).deletingLastPathComponent
        return dir.isEmpty ? "/" : dir
    }

    /// Parses an `ls -la`-style permission string (`-rw-r--r--`) into the
    /// octal mode `chmod` expects. Setuid/setgid/sticky bits aren't modelled
    /// (their column reads as non-`-` either way, so they fold into the
    /// nearest execute bit) — this is a best-effort restore for ordinary
    /// config files, not a full permissions round-trip.
    static func octalMode(fromPermissionString perms: String) -> Int? {
        let bits = Array(perms.dropFirst())
        guard bits.count == 9 else { return nil }
        let weights = [0o400, 0o200, 0o100, 0o040, 0o020, 0o010, 0o004, 0o002, 0o001]
        var mode = 0
        for (index, char) in bits.enumerated() where char != "-" {
            mode |= weights[index]
        }
        return mode
    }

    func mkdir(_ path: String) async throws {
        _ = try await run(batch: ["mkdir \(try quote(path))"])
    }

    func delete(_ file: RemoteFile, in directory: String) async throws {
        let target = directory.hasSuffix("/") ? directory + file.name : directory + "/" + file.name
        _ = try await run(batch: [(file.isDirectory ? "rmdir " : "rm ") + (try quote(target))])
    }

    // MARK: - Plumbing

    /// Rejects the control characters that `sftp` batch mode cannot carry.
    ///
    /// Quoting protects the *argument*, but a batch is newline-delimited: a
    /// name containing CR or LF splits one intended command into two, and the
    /// second half is whatever the filename says. That's not shell injection —
    /// it never reaches a shell — but it is command-stream injection into the
    /// sftp client, and `rm` is one of the commands it can forge. NUL simply
    /// truncates.
    ///
    /// Rejecting is the honest outcome rather than a limitation worth working
    /// around: `parseListing` reads `ls -la` line by line, so a name with an
    /// embedded newline can't survive a directory listing either. Failing at
    /// the boundary beats corrupting quietly further in.
    static func validateBatchPath(_ path: String) throws {
        guard !path.unicodeScalars.contains(where: {
            $0.value == 0x00 || $0.value == 0x0A || $0.value == 0x0D
        }) else {
            throw SFTPClientError.failed(
                "Paths containing NUL, carriage return, or line feed are not supported over SFTP."
            )
        }
    }

    private func quote(_ path: String) throws -> String {
        try Self.validateBatchPath(path)
        return "\"" + path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            + "\""
    }

    /// Set PORTSIDE_SFTP_DEBUG=1 to log raw sftp batches + output to Console.app.
    private static let debugLogging = ProcessInfo.processInfo.environment["PORTSIDE_SFTP_DEBUG"] != nil

    private func run(batch commands: [String]) async throws -> String {
        var args = ["-q", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
        args += SSHControl.options
        args += ["-b", "-"]
        args += entry.sftpTargetArgs

        let input = commands.joined(separator: "\n") + "\n"
        let result = try await Self.runProcess("/usr/bin/sftp", args, stdin: input)
        if Self.debugLogging {
            NSLog("Portside SFTP » commands:\n%@\n« status=%d\nstdout:\n%@\nstderr:\n%@",
                  input, result.status, result.out, result.err)
        }
        guard result.status == 0 else {
            let detail = result.err.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SFTPClientError.failed(detail.isEmpty ? "sftp exited with status \(result.status)" : detail)
        }
        return result.out
    }

    /// Holds the running process so a cancelled Task can kill it. A transfer
    /// that can't be stopped is the difference between a mis-click on a huge
    /// file being an annoyance and being a hostage situation, so cancellation
    /// has to reach the actual `sftp` child, not just abandon the await.
    private final class ProcessBox: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false
        private var launched = false

        /// Returns false if cancellation already happened, so the caller can
        /// avoid launching at all.
        func adopt(_ process: Process) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled else { return false }
            self.process = process
            return true
        }

        /// `terminate()` raises on a process that hasn't launched yet, but
        /// skipping it would let a cancel that lands in the gap between adopt
        /// and launch leak a transfer that runs to completion unattended.
        /// Handing the kill to whichever side arrives second covers both.
        func didLaunch() {
            lock.lock()
            launched = true
            let doomed = cancelled ? process : nil
            lock.unlock()
            doomed?.terminate()
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let running = launched ? process : nil
            lock.unlock()
            running?.terminate()
        }
    }

    static func runProcess(
        _ executable: String, _ args: [String], stdin: String
    ) async throws -> (status: Int32, out: String, err: String) {
        let box = ProcessBox()
        return try await withTaskCancellationHandler {
            try await runProcess(executable, args, stdin: stdin, box: box)
        } onCancel: {
            box.cancel()
        }
    }

    private static func runProcess(
        _ executable: String, _ args: [String], stdin: String, box: ProcessBox
    ) async throws -> (status: Int32, out: String, err: String) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = args
                guard box.adopt(process) else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let outPipe = Pipe()
                let errPipe = Pipe()
                let inPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                process.standardInput = inPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                box.didLaunch()

                inPipe.fileHandleForWriting.write(Data(stdin.utf8))
                inPipe.fileHandleForWriting.closeFile()

                // Drain stderr concurrently so a chatty pipe can't deadlock us.
                var errData = Data()
                let errQueue = DispatchQueue(label: "portside.sftp.stderr")
                let group = DispatchGroup()
                group.enter()
                errQueue.async {
                    errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }

                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()

                continuation.resume(returning: (
                    process.terminationStatus,
                    String(data: outData, encoding: .utf8) ?? "",
                    String(data: errData, encoding: .utf8) ?? ""
                ))
            }
        }
    }

    // MARK: - ls parsing

    /// A valid long-listing line starts with a 10-char mode string
    /// (type + 9 permission bits) optionally followed by an ACL/xattr marker.
    private static let modeRegex = try! NSRegularExpression(
        pattern: #"^[\-dlbcpsD?][rwxsStTlL\-]{9}[@+.]?$"#
    )

    /// Parses openssh `sftp` long-listing output. Rather than one brittle
    /// regex over the whole line (which breaks on unusual date/owner columns
    /// and left the browser silently empty), split on the eight fixed columns —
    /// mode, links, owner, group, size, month, day, time/year — and treat the
    /// rest as the name, so filenames with spaces and odd date formats survive.
    static func parseListing(_ output: String) -> [RemoteFile] {
        var files: [RemoteFile] = []
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("sftp>") || trimmed.hasPrefix("total ") { continue }

            let fields = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
            guard fields.count == 9 else { continue }
            let permissions = String(fields[0])
            let modeRange = NSRange(permissions.startIndex..., in: permissions)
            guard Self.modeRegex.firstMatch(in: permissions, range: modeRange) != nil else { continue }

            var name = String(fields[8])
            let isSymlink = permissions.hasPrefix("l")
            if isSymlink, let arrow = name.range(of: " -> ") {
                name = String(name[..<arrow.lowerBound])
            }
            // Some SFTP servers list absolute paths in the name column; a
            // filename can't contain "/", so reduce to the basename. This keeps
            // display, navigation, upload/download, and drag paths correct.
            name = (name as NSString).lastPathComponent
            if name == "." || name == ".." { continue }

            files.append(RemoteFile(
                name: name,
                isDirectory: permissions.hasPrefix("d"),
                isSymlink: isSymlink,
                size: Int(fields[4]) ?? 0,
                dateText: "\(fields[5]) \(fields[6]) \(fields[7])",
                permissions: permissions
            ))
        }
        return files.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
