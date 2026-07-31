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

    /// Reports a growing staging file into a `TransferCenter` entry.
    ///
    /// Batch `sftp` prints no progress of its own, but the drag payload
    /// carried the file's size, so watching the partial file grow gives a
    /// real percentage. Same 400ms cadence as the browser's own downloads.
    private static func pollStagedFile(
        _ staged: URL, into id: UUID, total: Int
    ) -> Task<Void, Never> {
        Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                let written = (try? FileManager.default
                    .attributesOfItem(atPath: staged.path)[.size] as? Int) ?? nil
                if let written {
                    TransferCenter.shared.rescale(id, transferred: written, total: total)
                }
            }
        }
    }

    /// Describes what is in flight when several uploads overlap.
    ///
    /// A strict "2 of 4" reads as one-at-a-time and stops being true the
    /// moment uploads run concurrently, so the label names a host and says how
    /// many others are alongside it. The completed count still comes from the
    /// bar itself.
    private static func inFlightLabel(
        file: String, hosts: [String], done: Int, total: Int
    ) -> String {
        let progress = "(\(done) of \(total))"
        guard let first = hosts.first else { return "Sending \(file) \(progress)…" }
        if hosts.count == 1 { return "Sending \(file) to \(first) \(progress)…" }
        return "Sending \(file) to \(first) +\(hosts.count - 1) more \(progress)…"
    }

    /// Tracks which hosts are mid-upload so the label can name them.
    private final class InFlight {
        private(set) var hosts: [String] = []
        var done = 0
        func started(_ name: String) { hosts.append(name) }
        func finished(_ name: String) {
            if let i = hosts.firstIndex(of: name) { hosts.remove(at: i) }
            done += 1
        }
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
        concurrency: Int = 4,
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

        var poll: Task<Void, Never>?
        let inFlight = InFlight()
        box.task = Task { @MainActor in
            defer {
                poll?.cancel()
                TransferCenter.shared.finish(id)
            }
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
                    concurrency: concurrency,
                    onPhase: { phase in
                        Task { @MainActor in
                            switch phase {
                            case .downloading(let staged):
                                poll = pollStagedFile(staged, into: id, total: payload.size)
                            case .uploading:
                                poll?.cancel()
                                // Switch the bar from bytes to hosts: the
                                // upload leg reports no bytes, but "3 of 8
                                // hosts" is the number that matters for a
                                // broadcast anyway.
                                TransferCenter.shared.rescale(
                                    id, transferred: 0, total: destinations.count
                                )
                                TransferCenter.shared.relabel(
                                    id, "Sending \(payload.name) to \(destinations.count) hosts…"
                                )
                            case .finished:
                                poll?.cancel()
                            }
                        }
                    },
                    onDeliveryStarted: { destination in
                        Task { @MainActor in
                            inFlight.started(destination.entry.name)
                            TransferCenter.shared.relabel(id, inFlightLabel(
                                file: payload.name, hosts: inFlight.hosts,
                                done: inFlight.done, total: destinations.count
                            ))
                        }
                    },
                    onDestination: { destination, outcome in
                        Task { @MainActor in
                            inFlight.finished(destination.entry.name)
                            if outcome == .delivered {
                                sessionsByEntry[destination.entry.id]?.flashRelayLanded()
                            }
                            TransferCenter.shared.rescale(
                                id, transferred: inFlight.done, total: destinations.count
                            )
                            TransferCenter.shared.relabel(id, inFlightLabel(
                                file: payload.name, hosts: inFlight.hosts,
                                done: inFlight.done, total: destinations.count
                            ))
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

    /// Uploads local files dropped on a pane to every host in `targets`.
    ///
    /// The symmetric case to a fan-out from a remote host: dropping from
    /// Finder onto a broadcasting pane should reach the group, exactly as
    /// dragging from the file browser does. Previously a Finder drag onto a
    /// pane did nothing at all, so the only route was dropping into the
    /// browser (which uploaded to that one host) and dragging it back out to
    /// the group.
    static func startLocalFanOut(
        urls: [URL],
        droppedOn: TerminalSession,
        targets: [Target],
        concurrency: Int = 4,
        operations: RemoteRelayTransfer.Operations = .live
    ) {
        guard !urls.isEmpty, !targets.isEmpty else { return }
        let reported = targets.map { ($0.entry, $0.session.currentDirectory) }
        let sessionsByEntry = Dictionary(
            targets.map { ($0.entry.id, $0.session) }, uniquingKeysWith: { first, _ in first }
        )

        let box = TaskBox()
        let label = urls.count == 1
            ? urls[0].lastPathComponent
            : "\(urls.count) files"
        let id = TransferCenter.shared.begin(
            entryID: droppedOn.entry?.id ?? UUID(),
            remotePath: urls[0].path,
            label: "Uploading \(label)…",
            cancel: { box.task?.cancel() }
        )

        let inFlight = InFlight()
        box.task = Task { @MainActor in
            defer { TransferCenter.shared.finish(id) }
            do {
                var destinations: [RemoteRelayTransfer.Destination] = []
                var seen: Set<String> = []
                for (entry, cwd) in reported {
                    let directory = try await RemoteRelayTransfer.resolveDirectory(
                        sessionCurrentDirectory: cwd, entry: entry, operations: operations
                    )
                    let key = "\(entry.id)|\(RemoteRelayTransfer.normalize(directory))"
                    guard seen.insert(key).inserted else { continue }
                    destinations.append(.init(entry: entry, directory: directory))
                }
                try Task.checkCancellation()

                var failures: [String] = []
                var delivered = 0
                var attempted = 0
                for url in urls {
                    let name = url.lastPathComponent
                    let results = try await RemoteRelayTransfer.runLocalFanOut(
                        localURL: url, name: name, destinations: destinations,
                        operations: operations, concurrency: concurrency,
                        onDeliveryStarted: { destination in
                            Task { @MainActor in
                                inFlight.started(destination.entry.name)
                                TransferCenter.shared.relabel(id, inFlightLabel(
                                    file: name, hosts: inFlight.hosts,
                                    done: inFlight.done, total: destinations.count
                                ))
                            }
                        },
                        onDestination: { destination, outcome in
                            Task { @MainActor in
                                inFlight.finished(destination.entry.name)
                                if outcome == .delivered {
                                    sessionsByEntry[destination.entry.id]?.flashRelayLanded()
                                }
                                TransferCenter.shared.rescale(
                                    id, transferred: inFlight.done, total: destinations.count
                                )
                                TransferCenter.shared.relabel(id, inFlightLabel(
                                    file: name, hosts: inFlight.hosts,
                                    done: inFlight.done, total: destinations.count
                                ))
                            }
                        }
                    )
                    attempted += results.count
                    delivered += results.filter { $0.1 == .delivered }.count
                    failures += results.compactMap { destination, outcome in
                        guard case .failed(let message) = outcome else { return nil }
                        return "\(destination.entry.name): \(name) — \(message)"
                    }
                }

                if !failures.isEmpty {
                    droppedOn.relayError = """
                    Uploaded \(delivered) of \(attempted).

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

        var poll: Task<Void, Never>?
        box.task = Task { @MainActor in
            defer {
                poll?.cancel()
                TransferCenter.shared.finish(id)
            }
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
                            case .downloading(let staged):
                                poll = pollStagedFile(staged, into: id, total: payload.size)
                                TransferCenter.shared.relabel(
                                    id, "Copying \(payload.name) from \(sourceEntry.name)…"
                                )
                            case .uploading:
                                poll?.cancel()
                                // No bytes to report on the way up (batch
                                // sftp prints none), so drop the bar to a
                                // spinner rather than leave it pinned at 100%
                                // for the whole second half.
                                TransferCenter.shared.rescale(id, transferred: 0, total: 0)
                                TransferCenter.shared.relabel(
                                    id, "Writing \(payload.name) to \(destinationEntry.name)…"
                                )
                            case .finished:
                                poll?.cancel()
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
