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

/// Accumulates bytes handed to it from a `FileHandle.readabilityHandler`,
/// which fires on a background queue outside the caller's control.
final class PipeDrain: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var collected: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

/// Runs saved port forwards as dedicated `ssh -N` processes and tracks their
/// health. Tunnels reuse an existing ControlMaster socket when the user
/// already has a terminal open to the host (no re-auth), but never *become*
/// the master — otherwise stopping a tunnel could tear down terminals and
/// SFTP sessions piggybacking on it.
final class TunnelManager: ObservableObject {
    @Published private(set) var statuses: [UUID: TunnelStatus] = [:]
    /// Mirrors the store so tunnels resolve credentials exactly as sessions do
    /// — including the default profile, which they previously ignored.
    var defaultProfileID: UUID?

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
        // Resolves the same way a session does. Checking only the host's own
        // Keychain entry meant a tunnel to a profile-backed host silently
        // failed to authenticate -- most visibly for auto-start tunnels, which
        // run before any session has established a ControlMaster to ride on.
        if let password = CredentialResolver.password(for: entry, defaultProfileID: defaultProfileID),
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
        let outPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = outPipe

        // Neither pipe was drained until the process exited. `ssh -N` writes
        // little, but enough banner/diagnostic output (a chatty ProxyCommand,
        // a verbose motd relayed some servers do) fills the OS pipe buffer,
        // blocks the child on write(), and since nothing was reading, it
        // never terminates — a tunnel that silently can't ever be torn down.
        // Draining continuously as bytes arrive, same as ContainerLister's
        // process runner, means the buffer can never fill in the first place.
        let errDrain = PipeDrain()
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { errDrain.append(chunk) }
        }
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil }
            // stdout content itself is never used — only draining it matters.
        }

        let id = forward.id
        process.terminationHandler = { [weak self] proc in
            cleanup?()
            // Stop the handlers before a final synchronous drain: the process
            // has already exited, so this can't block, and it catches any
            // last bytes that landed after the last handler callback.
            errPipe.fileHandleForReading.readabilityHandler = nil
            outPipe.fileHandleForReading.readabilityHandler = nil
            errDrain.append(errPipe.fileHandleForReading.readDataToEndOfFile())
            let stderr = String(data: errDrain.collected, encoding: .utf8) ?? ""
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
        terminate(process)
    }

    /// Asks the tunnel to exit, then insists.
    ///
    /// `terminate()` is SIGTERM and an ssh that has wedged — mid-handshake, or
    /// blocked on a ProxyCommand that is itself stuck — can sit through it.
    /// That leaves the local port bound by a process Portside believes it has
    /// stopped, so restarting the same forward fails with "address already in
    /// use" and the only way out is Activity Monitor.
    ///
    /// Same escalation `TerminalSession.shutdown` already uses, and for the
    /// same reason: ask nicely, then SIGKILL the process *group* after a grace
    /// period, since a ProxyCommand is a child of ssh and would otherwise
    /// outlive it. Captures the pid rather than the process so it doesn't
    /// matter that the entry is gone from `processes` by the time it runs.
    private func terminate(_ process: Process) {
        let pid = process.processIdentifier
        process.terminate()
        guard pid > 0 else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.terminateGrace) {
            if kill(pid, 0) == 0 { kill(-pid, SIGKILL) }
        }
    }

    /// How long a tunnel gets to exit on SIGTERM before it is killed outright.
    private static let terminateGrace: TimeInterval = 0.5

    /// Called when a forward is edited or deleted; a stale process would keep
    /// serving the old spec.
    func stopIfRunning(id: UUID) {
        guard let process = processes[id] else { return }
        stopRequested.insert(id)
        terminate(process)
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

    /// Tears every tunnel down at quit — synchronously, unlike `terminate`.
    ///
    /// The deferred SIGKILL is no use here: the app is on its way out and the
    /// background queue never gets to run it. A tunnel that sits through
    /// SIGTERM would then outlive Portside as an orphan still holding its
    /// local port, so the next launch can't rebind it and nothing on screen
    /// explains why.
    ///
    /// `ssh -N` has no state to flush, so escalating quickly costs nothing.
    /// The wait is bounded and short — quitting must not visibly hang on a
    /// wedged tunnel either.
    private func terminateAllProcesses() {
        let running = processes.values.filter(\.isRunning)
        for process in running { process.terminate() }

        let deadline = Date().addingTimeInterval(Self.terminateGrace)
        while Date() < deadline, running.contains(where: \.isRunning) {
            usleep(20_000)
        }
        for process in running where process.isRunning {
            let pid = process.processIdentifier
            if pid > 0, kill(pid, 0) == 0 { kill(-pid, SIGKILL) }
        }
    }
}
