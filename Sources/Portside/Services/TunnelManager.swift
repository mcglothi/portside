import AppKit
import Foundation

enum TunnelStatus: Equatable {
    case stopped
    case connecting
    case running
    case failed(String)

    var isActive: Bool {
        switch self {
        case .connecting, .running: return true
        case .stopped, .failed: return false
        }
    }
}

/// Runs saved port forwards as dedicated `ssh -N` processes and tracks their
/// health. Tunnels reuse an existing ControlMaster socket when the user
/// already has a terminal open to the host (no re-auth), but never *become*
/// the master — otherwise stopping a tunnel could tear down terminals and
/// SFTP sessions piggybacking on it.
final class TunnelManager: ObservableObject {
    @Published private(set) var statuses: [UUID: TunnelStatus] = [:]

    private var processes: [UUID: Process] = [:]
    /// Forwards the user stopped on purpose, so termination reads as
    /// .stopped instead of .failed.
    private var stopRequested: Set<UUID> = []
    private var quitObserver: NSObjectProtocol?

    init() {
        // ssh -N children are not tied to a pty and would outlive the app;
        // kill them explicitly on quit.
        quitObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.terminateAllProcesses()
        }
    }

    deinit {
        if let quitObserver {
            NotificationCenter.default.removeObserver(quitObserver)
        }
        terminateAllProcesses()
    }

    func status(of forward: PortForward) -> TunnelStatus {
        statuses[forward.id] ?? .stopped
    }

    var activeCount: Int {
        statuses.values.filter(\.isActive).count
    }

    /// Launches the tunnel through `entry` (already resolved against
    /// connection defaults). No-op if it's already up.
    func start(_ forward: PortForward, via entry: SessionEntry) {
        guard processes[forward.id] == nil else { return }
        stopRequested.remove(forward.id)

        var args = [
            "-N",                                    // forward only, no shell
            "-o", "ExitOnForwardFailure=yes",        // die loudly if the bind fails
            "-o", "ConnectTimeout=15",
        ]
        args += SSHControl.passiveOptions
        args += [forward.kind.flag, forward.spec]
        args += entry.sshArgs

        var environment = ProcessInfo.processInfo.environment
        var cleanup: (() -> Void)?
        if entry.savePassword, let password = CredentialStore.password(for: entry.id),
           let injected = AskpassInjector.environment(for: password) {
            for pair in injected.env {
                if let eq = pair.firstIndex(of: "=") {
                    environment[String(pair[..<eq])] = String(pair[pair.index(after: eq)...])
                }
            }
            cleanup = injected.cleanup
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = args
        process.environment = environment
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()

        let id = forward.id
        process.terminationHandler = { [weak self] proc in
            cleanup?()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                self?.finish(id: id, status: proc.terminationStatus, stderr: stderr)
            }
        }

        do {
            try process.run()
        } catch {
            cleanup?()
            statuses[id] = .failed(error.localizedDescription)
            return
        }

        processes[id] = process
        statuses[id] = .connecting
        // ExitOnForwardFailure makes bad tunnels exit fast, so a process
        // still alive shortly after launch has (almost certainly) bound its
        // port. Promote it; failures flip the state via terminationHandler.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.processes[id] != nil,
                  self.statuses[id] == .connecting else { return }
            self.statuses[id] = .running
        }

        // Cap how long a stashed askpass secret can sit on disk (same bound
        // SessionManager uses for interactive sessions).
        if cleanup != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { cleanup?() }
        }
    }

    func stop(_ forward: PortForward) {
        guard let process = processes[forward.id] else { return }
        stopRequested.insert(forward.id)
        process.terminate()
    }

    /// Called when a forward is edited or deleted; a stale process would keep
    /// serving the old spec.
    func stopIfRunning(id: UUID) {
        guard let process = processes[id] else { return }
        stopRequested.insert(id)
        process.terminate()
    }

    /// Brings up every autoStart tunnel that has a resolvable host.
    func startAutoStartTunnels(forwards: [PortForward], entryFor: (UUID) -> SessionEntry?) {
        for forward in forwards where forward.autoStart {
            guard let hostID = forward.hostID, let entry = entryFor(hostID) else { continue }
            start(forward, via: entry)
        }
    }

    private func finish(id: UUID, status: Int32, stderr: String) {
        processes[id] = nil
        if stopRequested.remove(id) != nil {
            statuses[id] = .stopped
        } else {
            let detail = stderr
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .suffix(2)
                .joined(separator: " — ")
            statuses[id] = .failed(detail.isEmpty ? "ssh exited with status \(status)" : detail)
        }
    }

    private func terminateAllProcesses() {
        for process in processes.values where process.isRunning {
            process.terminate()
        }
    }
}
