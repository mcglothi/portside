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

    private func run(batch commands: [String]) async throws -> String {
        var args = ["-q", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
        args += SSHControl.options
        args += ["-b", "-"]
        args += entry.sftpTargetArgs

        let input = commands.joined(separator: "\n") + "\n"
        let result = try await Self.runProcess("/usr/bin/sftp", args, stdin: input)
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

    private static let listingRegex = try! NSRegularExpression(
        pattern: #"^([\-dlbcps][rwxsStT\-]{9}[@+.]?)\s+\d+\s+\S+\s+\S+\s+(\d+)\s+(\S+\s+\d+\s+\S+)\s+(.+)$"#
    )

    static func parseListing(_ output: String) -> [RemoteFile] {
        var files: [RemoteFile] = []
        for line in output.components(separatedBy: .newlines) {
            if line.hasPrefix("sftp>") || line.isEmpty { continue }
            let range = NSRange(line.startIndex..., in: line)
            guard let match = listingRegex.firstMatch(in: line, range: range),
                  let permsRange = Range(match.range(at: 1), in: line),
                  let sizeRange = Range(match.range(at: 2), in: line),
                  let dateRange = Range(match.range(at: 3), in: line),
                  let nameRange = Range(match.range(at: 4), in: line)
            else { continue }

            let permissions = String(line[permsRange])
            var name = String(line[nameRange])
            let isSymlink = permissions.hasPrefix("l")
            if isSymlink, let arrow = name.range(of: " -> ") {
                name = String(name[..<arrow.lowerBound])
            }
            if name == "." || name == ".." { continue }

            files.append(RemoteFile(
                name: name,
                isDirectory: permissions.hasPrefix("d"),
                isSymlink: isSymlink,
                size: Int(line[sizeRange]) ?? 0,
                dateText: String(line[dateRange]),
                permissions: permissions
            ))
        }
        return files.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
