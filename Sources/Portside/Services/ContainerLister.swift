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

/// Lists running containers (`docker/podman ps`) or Kubernetes workloads and pods
/// over a session's transport — locally, or over SSH reusing the same
/// ControlMaster socket the interactive session and SFTP pane use, so an open
/// session means no re-auth.
enum ContainerLister {
    static func list(for entry: SessionEntry) async throws -> [RunningContainer] {
        guard let command = enumerationCommand(for: entry) else {
            throw ContainerListerError.failed("Only container and Kubernetes sessions can be browsed.")
        }
        let output = try await run(command: command, entry: entry)
        return entry.kind == .kubernetes ? try parseWorkloads(output) : parseContainers(output)
    }

    /// The target's binary and selection flags, then `tail`, for a command run
    /// on the entry's transport.
    static func kubernetesArguments(_ entry: SessionEntry, _ tail: [String]) -> [String] {
        (entry.kubernetes ?? KubernetesTarget()).baseArguments(local: entry.usesLocalTransport) + tail
    }

    // MARK: - Kubernetes discovery

    struct KubeContext: Hashable, Identifiable {
        var id: String { name }
        let name: String
        let cluster: String
        let namespace: String
    }

    /// The contexts in the entry's kubeconfig — `$KUBECONFIG` or
    /// `~/.kube/config` unless the entry names a file — and which is current.
    /// Asked of the CLI rather than read as YAML here: it merges several
    /// files the way the session's own kubectl will.
    static func contexts(for entry: SessionEntry) async throws -> (contexts: [KubeContext], current: String?) {
        var target = entry.kubernetes ?? KubernetesTarget()
        target.context = ""     // every context in the file, not just the chosen one
        target.namespace = ""
        var probe = entry
        probe.kubernetes = target
        let command = ShellQuoting.command(kubernetesArguments(probe, ["config", "view", "-o", "json"]))
        return try parseContexts(try await run(command: command, entry: entry))
    }

    /// The containers of the chosen pod or workload, and the one kubectl uses
    /// when none is named (`kubectl.kubernetes.io/default-container`, else
    /// the first).
    static func containers(for entry: SessionEntry) async throws -> (names: [String], defaultName: String?) {
        let target = (entry.kubernetes?.pod ?? "").trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty, !target.looksLikeShellOption else {
            throw ContainerListerError.failed("Choose a pod or workload first.")
        }
        let resource = target.contains("/") ? target : "pod/\(target)"
        let command = ShellQuoting.command(kubernetesArguments(entry, ["get", resource, "-o", "json"]))
        return try parseContainerNames(try await run(command: command, entry: entry))
    }

    /// The `ps` / `get pods` command for this entry, or nil for plain hosts.
    ///
    /// Built as an argument array and quoted once at the end. Context and
    /// namespace come from the session library, which can be imported from a
    /// file someone else wrote — joining them in raw let a crafted namespace
    /// run arbitrary commands the moment the user browsed pods.
    static func enumerationCommand(for entry: SessionEntry) -> String? {
        enumerationArguments(for: entry).map(ShellQuoting.command)
    }

    /// The same command as an argument array, for callers that can execute
    /// without a shell at all.
    static func enumerationArguments(for entry: SessionEntry) -> [String]? {
        switch entry.kind {
        case .container:
            let engine = entry.container?.engine.rawValue ?? "docker"
            return [engine, "ps", "--format", "{{.Names}}\t{{.Image}}\t{{.Status}}"]
        case .kubernetes:
            // Workloads as well as pods: a pod is renamed on every rollout, so
            // a saved entry is better pointed at `deploy/web` than at one of
            // its replicas. JSON, because the table form's columns differ per
            // kind and between kubectl versions.
            return kubernetesArguments(entry, ["get", "deployments,statefulsets,daemonsets,pods", "-o", "json"])
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

    private static func json(_ output: String) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any] else {
            throw ContainerListerError.failed("Couldn\u{2019}t read the cluster\u{2019}s answer.")
        }
        return object
    }

    /// `get deployments,statefulsets,daemonsets,pods -o json` as picker rows:
    /// workloads first, as `deploy/web` — the name kubectl exec takes and that
    /// survives a rollout — then pods.
    static func parseWorkloads(_ output: String) throws -> [RunningContainer] {
        let items = (try json(output)["items"] as? [[String: Any]]) ?? []
        let short = ["Deployment": "deploy", "StatefulSet": "sts", "DaemonSet": "ds"]
        var workloads: [RunningContainer] = [], pods: [RunningContainer] = []
        for item in items {
            guard let kind = item["kind"] as? String,
                  let name = (item["metadata"] as? [String: Any])?["name"] as? String, !name.isEmpty else { continue }
            let status = item["status"] as? [String: Any] ?? [:]
            if let prefix = short[kind] {
                let ready = status["readyReplicas"] as? Int ?? status["numberReady"] as? Int ?? 0
                let want = (item["spec"] as? [String: Any])?["replicas"] as? Int
                    ?? status["desiredNumberScheduled"] as? Int ?? 0
                workloads.append(RunningContainer(name: "\(prefix)/\(name)",
                                                  detail: "\(kind) · \(ready)/\(want) ready"))
            } else if kind == "Pod" {
                let phase = status["phase"] as? String ?? ""
                let statuses = status["containerStatuses"] as? [[String: Any]] ?? []
                let ready = statuses.filter { $0["ready"] as? Bool == true }.count
                let detail = [phase, statuses.isEmpty ? "" : "ready \(ready)/\(statuses.count)"]
                    .filter { !$0.isEmpty }.joined(separator: " · ")
                pods.append(RunningContainer(name: name, detail: detail))
            }
        }
        return workloads.sorted { $0.name < $1.name } + pods.sorted { $0.name < $1.name }
    }

    static func parseContexts(_ output: String) throws -> (contexts: [KubeContext], current: String?) {
        let config = try json(output)
        let contexts = (config["contexts"] as? [[String: Any]] ?? []).compactMap { c -> KubeContext? in
            guard let name = c["name"] as? String, !name.isEmpty else { return nil }
            let detail = c["context"] as? [String: Any] ?? [:]
            return KubeContext(name: name, cluster: detail["cluster"] as? String ?? "",
                               namespace: detail["namespace"] as? String ?? "")
        }
        let current = (config["current-context"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (contexts.sorted { $0.name < $1.name }, current)
    }

    /// Containers from a pod, or from a workload's pod template.
    static func parseContainerNames(_ output: String) throws -> (names: [String], defaultName: String?) {
        let object = try json(output)
        let spec = object["spec"] as? [String: Any] ?? [:]
        let template = spec["template"] as? [String: Any]
        let podSpec = (template?["spec"] as? [String: Any]) ?? spec
        let metadata = (template?["metadata"] as? [String: Any]) ?? (object["metadata"] as? [String: Any]) ?? [:]
        let names = (podSpec["containers"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        let annotated = (metadata["annotations"] as? [String: Any])?["kubectl.kubernetes.io/default-container"] as? String
        return (names, annotated.flatMap { names.contains($0) ? $0 : nil } ?? names.first)
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
