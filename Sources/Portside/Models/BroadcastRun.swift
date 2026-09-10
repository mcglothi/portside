import Foundation

/// What happened on each host after one MultiExec broadcast.
///
/// MultiExec sends keystrokes and, until now, said nothing about what came
/// back: `docs/multiexec.md` listed "no confirmation of what actually ran"
/// under what it does not do. The shell-integration timeline already reports
/// command boundaries and exit statuses per session, so for hosts that report
/// them the answer exists — it just was not collected.
///
/// **The hard part is not collecting results, it is not overclaiming them.**
/// A host with no shell integration will never report anything; a pane sitting
/// in `vim` or a pager receives the keystrokes and emits no command boundary at
/// all; and an exit status arriving from a host may belong to something the
/// user typed there rather than to the broadcast. Each of those is reported as
/// what it is. Nothing here infers success from silence, and nothing here
/// retries: a host that did not answer is shown as not having answered.
struct BroadcastRun: Identifiable, Equatable {
    let id: UUID
    /// Exactly what was sent, used to tell "this finished" from "something
    /// else finished".
    let command: String
    let startedAt: Date
    private(set) var results: [BroadcastResult]

    init(id: UUID = UUID(), command: String, startedAt: Date, results: [BroadcastResult]) {
        self.id = id
        self.command = command
        self.startedAt = startedAt
        self.results = results
    }

    /// True once no result can change on its own — every host has either
    /// reported, diverged, or was never going to report.
    var isSettled: Bool {
        results.allSatisfy(\.isSettled)
    }

    var summary: String {
        let finished = results.filter { if case .finished = $0.outcome { return true } else { return false } }
        let failed = finished.filter { $0.exitCode != 0 && $0.exitCode != nil }
        var parts = ["\(finished.count) of \(results.count) reported"]
        if !failed.isEmpty { parts.append("\(failed.count) non-zero") }
        let silent = results.filter { if case .unobservable = $0.outcome { return true } else { return false } }
        if !silent.isEmpty { parts.append("\(silent.count) cannot report") }
        return parts.joined(separator: " · ")
    }

    /// Folds one shell-integration event into this run.
    ///
    /// Events that began before the broadcast are ignored outright: they
    /// belong to whatever the user was doing beforehand, and attributing one
    /// would report a stale exit status as this command's.
    mutating func record(event: CommandEvent, from sessionID: UUID) {
        guard let index = results.firstIndex(where: { $0.sessionID == sessionID }) else { return }
        // A recorded outcome is final: whatever the user does in that pane
        // afterwards is not this broadcast. `.unobservable` is deliberately
        // *not* final — it means "this host has not reported before", which is
        // a statement about the past, not a promise about the future. A host
        // reporting for the first time upgrades out of it.
        guard !results[index].isFinal else { return }
        guard event.startedAt >= startedAt else { return }

        let observed = event.command.trimmingCharacters(in: .whitespacesAndNewlines)
        let expected = command.trimmingCharacters(in: .whitespacesAndNewlines)

        if !observed.isEmpty, observed != expected {
            // Something else ran here. Reporting its exit status as the
            // broadcast's would be a plain lie, and staying silent would hide
            // that this host did not run what the others did.
            results[index].outcome = .diverged(observed: observed)
            return
        }

        guard let finishedAt = event.finishedAt else {
            results[index].outcome = .running(since: event.startedAt)
            return
        }

        results[index].outcome = .finished(
            exitCode: event.exitCode,
            at: finishedAt,
            // An empty command string is bash's DEBUG trap failing to supply
            // one. The timing still places the event after the broadcast, but
            // it is a weaker claim and is labelled as one rather than
            // presented as a confirmed match.
            attribution: observed.isEmpty ? .timingOnly : .commandMatched
        )
    }
}

/// One host's outcome within a broadcast.
struct BroadcastResult: Identifiable, Equatable {
    let sessionID: UUID
    /// The pane's title, so the row names a host rather than a UUID.
    let host: String
    var outcome: Outcome

    var id: UUID { sessionID }

    enum Attribution: Equatable {
        /// The shell reported the command text and it matched what was sent.
        case commandMatched
        /// The shell reported a boundary without command text, so this is the
        /// first command to finish after the broadcast — probably ours, but
        /// not confirmed to be.
        case timingOnly
    }

    enum Outcome: Equatable {
        /// Keystrokes delivered. This session has reported command boundaries
        /// before, so a result is expected.
        case awaitingReport
        /// Delivered, and nothing will come back. Not a failure and not a
        /// success — Portside cannot see what happened here.
        case unobservable(reason: String)
        case running(since: Date)
        case finished(exitCode: Int?, at: Date, attribution: Attribution)
        /// A different command finished on this host. The broadcast may still
        /// be queued behind it, but this host is not in step with the others.
        case diverged(observed: String)
    }

    /// Whether the run should stop waiting on this host. An unobservable host
    /// counts, because waiting on it forever would make the run look pending
    /// when nothing is coming.
    var isSettled: Bool {
        switch outcome {
        case .finished, .unobservable, .diverged: return true
        case .awaitingReport, .running: return false
        }
    }

    /// Whether this outcome is a recorded fact that later events must not
    /// overwrite. Narrower than `isSettled` on purpose.
    var isFinal: Bool {
        switch outcome {
        case .finished, .diverged: return true
        case .awaitingReport, .running, .unobservable: return false
        }
    }

    var exitCode: Int? {
        if case .finished(let code, _, _) = outcome { return code }
        return nil
    }

    /// One line for this host, worded so that "we don't know" never reads as
    /// "it worked".
    var label: String {
        switch outcome {
        case .awaitingReport:
            return "Sent — waiting for this host to report"
        case .unobservable(let reason):
            return reason
        case .running(let since):
            return "Running since \(Self.time.string(from: since))"
        case .finished(let code, _, let attribution):
            let status: String
            switch code {
            case 0?: status = "Finished, exit 0"
            case let code?: status = "Finished, exit \(code)"
            case nil: status = "Finished, exit status not reported"
            }
            return attribution == .timingOnly
                ? status + " (matched by timing — the shell didn't name the command)"
                : status
        case .diverged(let observed):
            return "A different command finished here: \(observed)"
        }
    }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
