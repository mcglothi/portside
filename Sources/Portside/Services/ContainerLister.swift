import Foundation

/// A running container or pod discovered on a session's transport.
struct RunningContainer: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let detail: String   // image · status, or pod status · ready
}

enum ContainerListerError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        }
    }
}

/// Lists running containers (`docker/podman ps`) or pods (`kubectl get pods`)
/// over a session's transport — locally, or over SSH reusing the same
/// ControlMaster socket the interactive session and SFTP pane use, so an open
/// session means no re-auth.
enum ContainerLister {
    static func list(for entry: SessionEntry) async throws -> [RunningContainer] {
        guard let command = enumerationCommand(for: entry) else {
            throw ContainerListerError.failed("Only container and Kubernetes sessions can be browsed.")
        }
        let output = try await run(command: command, entry: entry)
        return entry.kind == .kubernetes ? parsePods(output) : parseContainers(output)
    }

    /// The `ps` / `get pods` command for this entry, or nil for plain hosts.
    static func enumerationCommand(for entry: SessionEntry) -> String? {
        switch entry.kind {
        case .container:
            let engine = entry.container?.engine.rawValue ?? "docker"
            return "\(engine) ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}'"
        case .kubernetes:
            var parts = ["kubectl"]
            if let ctx = entry.kubernetes?.context.trimmingCharacters(in: .whitespaces), !ctx.isEmpty {
                parts += ["--context", ctx]
            }
            if let ns = entry.kubernetes?.namespace.trimmingCharacters(in: .whitespaces), !ns.isEmpty {
                parts += ["-n", ns]
            }
            parts += ["get", "pods", "--no-headers"]
            return parts.joined(separator: " ")
        case .host, .serial, .telnet:
            return nil
        }
    }

    // MARK: - Transport

    private static func run(command: String, entry: SessionEntry) async throws -> String {
        let executable: String
        let args: [String]

        if entry.usesLocalTransport {
            // Login shell so docker/kubectl/gcloud are on PATH, same as the
            // interactive session will get.
            executable = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            args = ["-lc", command]
        } else {
            executable = "/usr/bin/ssh"
            var a = ["-q", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
            a += SSHControl.options
            a += entry.sshArgs
            a.append(command)
            args = a
        }

        let result = try await runProcess(executable, args)
        guard result.status == 0 else {
            let detail = result.err.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ContainerListerError.failed(detail.isEmpty
                ? "Command exited with status \(result.status)."
                : detail)
        }
        return result.out
    }

    // MARK: - Parsing

    static func parseContainers(_ output: String) -> [RunningContainer] {
        output.components(separatedBy: .newlines).compactMap { line in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            let fields = line.components(separatedBy: "\t")
            let name = fields[0].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            let image = fields.count > 1 ? fields[1].trimmingCharacters(in: .whitespaces) : ""
            let status = fields.count > 2 ? fields[2].trimmingCharacters(in: .whitespaces) : ""
            let detail = [image, status].filter { !$0.isEmpty }.joined(separator: " · ")
            return RunningContainer(name: name, detail: detail)
        }
    }

    static func parsePods(_ output: String) -> [RunningContainer] {
        output.components(separatedBy: .newlines).compactMap { line in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let name = fields.first, !name.isEmpty else { return nil }
            let ready = fields.count > 1 ? fields[1] : ""
            let status = fields.count > 2 ? fields[2] : ""
            let detail = [status, ready.isEmpty ? "" : "ready \(ready)"]
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            return RunningContainer(name: name, detail: detail)
        }
    }

    // MARK: - Process

    private static func runProcess(
        _ executable: String, _ args: [String]
    ) async throws -> (status: Int32, out: String, err: String) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = args
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                // Drain stderr concurrently so a chatty pipe can't deadlock us.
                var errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
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
}
