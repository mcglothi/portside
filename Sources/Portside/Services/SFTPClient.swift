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
    static let controlDir = "/tmp/portside-ssh"

    static var options: [String] {
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
        let out = try await run(batch: ["ls -la \(quote(path))"])
        return Self.parseListing(out)
    }

    func download(remotePath: String, to localURL: URL) async throws {
        _ = try await run(batch: ["get \(quote(remotePath)) \(quote(localURL.path))"])
    }

    func upload(localURL: URL, toDirectory remoteDir: String) async throws {
        _ = try await run(batch: [
            "cd \(quote(remoteDir))",
            "put \(quote(localURL.path))",
        ])
    }

    func mkdir(_ path: String) async throws {
        _ = try await run(batch: ["mkdir \(quote(path))"])
    }

    func delete(_ file: RemoteFile, in directory: String) async throws {
        let target = directory.hasSuffix("/") ? directory + file.name : directory + "/" + file.name
        _ = try await run(batch: [(file.isDirectory ? "rmdir " : "rm ") + quote(target)])
    }

    // MARK: - Plumbing

    private func quote(_ path: String) -> String {
        "\"" + path
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

    private static func runProcess(
        _ executable: String, _ args: [String], stdin: String
    ) async throws -> (status: Int32, out: String, err: String) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = args
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
