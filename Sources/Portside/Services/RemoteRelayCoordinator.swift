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
