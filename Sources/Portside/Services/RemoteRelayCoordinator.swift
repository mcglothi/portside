import Foundation

/// Drives one dropped host-to-host copy: resolves where it lands, runs the
/// relay, and reports progress and failure where the user is looking.
///
/// Split from `RemoteRelayTransfer` so the transfer itself stays free of
/// `TransferCenter`, sessions and the main actor, and can be tested without
/// any of them.
@MainActor
enum RemoteRelayCoordinator {

    /// Holds the running task so the progress entry's Cancel button has
    /// something to cancel. The entry has to exist before the task starts
    /// (otherwise a fast failure finishes a transfer that was never shown),
    /// and the task has to exist before the entry's cancel hook can reference
    /// it — so one of them is filled in a moment late.
    private final class TaskBox {
        var task: Task<Void, Never>?
    }

    /// One pane a fan-out will deliver to.
    struct Target {
        let session: TerminalSession
        let entry: SessionEntry
    }

    /// Copies one file to every pane in `targets`, downloading it once.
    ///
    /// Progress shows per host, on each destination's own pane, because that
    /// is where `TransferCenter` files entries and where the user will look
    /// to see whether their box got it. Failures are collected and reported
    /// together on the pane the file was dropped on, rather than as one alert
    /// per host — a broadcast to eight hosts where three are full should be
    /// one message, not three dialogs.
    static func startFanOut(
        payload: RemoteFileDragPayload,
        sourceEntry: SessionEntry,
        droppedOn: TerminalSession,
        targets: [Target],
        operations: RemoteRelayTransfer.Operations = .live
    ) {
        let source = RemoteRelayTransfer.Source(
            entry: sourceEntry, remotePath: payload.remotePath,
            name: payload.name, size: payload.size
        )
        let reported = targets.map { ($0.entry, $0.session.currentDirectory) }

        let box = TaskBox()
        let id = TransferCenter.shared.begin(
            entryID: sourceEntry.id,
            remotePath: payload.remotePath,
            label: "Reading \(payload.name) from \(sourceEntry.name)…",
            total: payload.size,
            cancel: { box.task?.cancel() }
        )

        box.task = Task { @MainActor in
            defer { TransferCenter.shared.finish(id) }
            do {
                var destinations: [RemoteRelayTransfer.Destination] = []
                var seen: Set<String> = []
                for (entry, cwd) in reported {
                    let directory = try await RemoteRelayTransfer.resolveDirectory(
                        sessionCurrentDirectory: cwd, entry: entry, operations: operations
                    )
                    // Two panes on the same host in the same directory are one
                    // destination; delivering twice would make the second a
                    // spurious collision against the file just written.
                    let key = "\(entry.id)|\(RemoteRelayTransfer.normalize(directory))"
                    guard seen.insert(key).inserted else { continue }
                    destinations.append(.init(entry: entry, directory: directory))
                }
                try Task.checkCancellation()

                let sessionsByEntry = Dictionary(
                    targets.map { ($0.entry.id, $0.session) }, uniquingKeysWith: { first, _ in first }
                )
                let results = try await RemoteRelayTransfer.runFanOut(
                    source: source, destinations: destinations, operations: operations,
                    onPhase: { phase in
                        Task { @MainActor in
                            guard phase == .uploading else { return }
                            TransferCenter.shared.relabel(
                                id, "Sending \(payload.name) to \(destinations.count) host(s)…"
                            )
                        }
                    },
                    onDestination: { destination, outcome in
                        guard outcome == .delivered else { return }
                        Task { @MainActor in
                            sessionsByEntry[destination.entry.id]?.flashRelayLanded()
                        }
                    }
                )

                let failures = results.compactMap { destination, outcome -> String? in
                    guard case .failed(let message) = outcome else { return nil }
                    return "\(destination.entry.name): \(message)"
                }
                if !failures.isEmpty {
                    let delivered = results.filter { $0.1 == .delivered }.count
                    let skipped = results.filter { $0.1 == .skipped }.count
                    // Every host has to be accounted for. Reporting "2 of 4"
                    // with one failure listed leaves the reader hunting for a
                    // fourth host that was only ever skipped because it is
                    // where the file came from.
                    var summary = "Copied to \(delivered) of \(results.count) hosts."
                    if skipped > 0 {
                        summary += " \(skipped) already had it."
                    }
                    droppedOn.relayError = """
                    \(summary)

                    \(failures.joined(separator: "\n"))
                    """
                }
            } catch is CancellationError {
                // Nothing to report: the user asked for this.
            } catch {
                droppedOn.relayError = error.localizedDescription
            }
        }
    }

    /// Starts a relay for a file dropped on `destinationSession`'s pane.
    ///
    /// Returns immediately; progress appears in the destination host's
    /// transfer list and any failure on the destination pane, because that is
    /// the pane the user dropped onto and the one they are watching.
    static func start(
        payload: RemoteFileDragPayload,
        sourceEntry: SessionEntry,
        destinationSession: TerminalSession,
        destinationEntry: SessionEntry,
        operations: RemoteRelayTransfer.Operations = .live
    ) {
        let source = RemoteRelayTransfer.Source(
            entry: sourceEntry, remotePath: payload.remotePath,
            name: payload.name, size: payload.size
        )
        let reported = destinationSession.currentDirectory

        let box = TaskBox()
        let id = TransferCenter.shared.begin(
            entryID: destinationEntry.id,
            remotePath: payload.remotePath,
            label: "Copying \(payload.name) from \(sourceEntry.name)…",
            total: payload.size,
            cancel: { box.task?.cancel() }
        )

        box.task = Task { @MainActor in
            defer { TransferCenter.shared.finish(id) }
            do {
                let directory = try await RemoteRelayTransfer.resolveDirectory(
                    sessionCurrentDirectory: reported, entry: destinationEntry,
                    operations: operations
                )
                try Task.checkCancellation()

                try await RemoteRelayTransfer.run(
                    source: source,
                    destination: .init(entry: destinationEntry, directory: directory),
                    operations: operations,
                    onPhase: { phase in
                        Task { @MainActor in
                            switch phase {
                            case .downloading:
                                TransferCenter.shared.relabel(
                                    id, "Copying \(payload.name) from \(sourceEntry.name)…"
                                )
                            case .uploading:
                                TransferCenter.shared.relabel(
                                    id, "Writing \(payload.name) to \(destinationEntry.name)…"
                                )
                            case .finished:
                                break
                            }
                        }
                    }
                )
            } catch is CancellationError {
                // Nothing to report: the user asked for this.
            } catch {
                destinationSession.relayError = error.localizedDescription
            }
        }
    }
}
