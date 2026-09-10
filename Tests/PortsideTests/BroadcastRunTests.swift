import XCTest
@testable import Portside

/// MultiExec previously collected nothing, and `docs/multiexec.md` said so.
/// Collecting results is easy; the risk in doing it is that a per-host report
/// which quietly guesses is worse than no report at all — someone will run a
/// destructive command across forty hosts and read this panel to decide
/// whether it worked. Every test here is about refusing to overclaim.
final class BroadcastRunTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_000_000)
    private let hostA = UUID()
    private let hostB = UUID()

    // MARK: - The ordinary case

    func testAMatchingCommandIsReportedWithItsExitStatus() {
        var run = makeRun(command: "uptime")
        run.record(
            event: event(command: "uptime", started: start + 1, finished: start + 2, exit: 0),
            from: hostA
        )
        XCTAssertEqual(
            result(run, hostA).outcome,
            .finished(exitCode: 0, at: start + 2, attribution: .commandMatched)
        )
    }

    func testANonZeroExitIsNotSmoothedOver() {
        var run = makeRun(command: "systemctl restart nginx")
        run.record(
            event: event(command: "systemctl restart nginx",
                         started: start + 1, finished: start + 2, exit: 1),
            from: hostA
        )
        XCTAssertEqual(result(run, hostA).exitCode, 1)
        XCTAssertTrue(result(run, hostA).label.contains("exit 1"))
    }

    func testACommandStillRunningIsNotReportedAsFinished() {
        var run = makeRun(command: "apt upgrade -y")
        run.record(
            event: event(command: "apt upgrade -y", started: start + 1, finished: nil, exit: nil),
            from: hostA
        )
        XCTAssertEqual(result(run, hostA).outcome, .running(since: start + 1))
        XCTAssertFalse(result(run, hostA).isSettled)
    }

    // MARK: - Silence is never success

    func testAHostThatCannotReportSaysSoRatherThanLookingPending() {
        // No shell integration: nothing will ever arrive for this host. Left
        // as "waiting", the row would look like a result was still coming and
        // eventually read as though it had been fine.
        let run = BroadcastRun(
            command: "uptime", startedAt: start,
            results: [
                BroadcastResult(
                    sessionID: hostA,
                    host: "legacy-box",
                    outcome: .unobservable(reason: "This host doesn't report command results.")
                )
            ]
        )
        XCTAssertTrue(result(run, hostA).isSettled)
        XCTAssertFalse(result(run, hostA).label.lowercased().contains("waiting"))
        XCTAssertNil(result(run, hostA).exitCode, "an unobservable host has no exit status")
    }

    func testAnUnansweredHostNeverBecomesASuccess() {
        // The whole run settling must not turn a silent host into a good one.
        var run = makeRun(command: "uptime")
        run.record(
            event: event(command: "uptime", started: start + 1, finished: start + 2, exit: 0),
            from: hostA
        )
        XCTAssertFalse(run.isSettled, "hostB has not reported, so the run is not settled")
        XCTAssertNil(result(run, hostB).exitCode)
        XCTAssertEqual(result(run, hostB).outcome, .awaitingReport)
    }

    // MARK: - Attribution

    func testADifferentCommandFinishingIsReportedAsDivergenceNotAsOurResult() {
        // Someone was typing in that pane. Reporting its exit 0 as the
        // broadcast's result is the exact failure this panel must not have.
        var run = makeRun(command: "systemctl restart nginx")
        run.record(
            event: event(command: "ls", started: start + 1, finished: start + 2, exit: 0),
            from: hostA
        )
        XCTAssertEqual(result(run, hostA).outcome, .diverged(observed: "ls"))
        XCTAssertNil(result(run, hostA).exitCode, "a divergent command contributes no exit status")
    }

    func testAnEventFromBeforeTheBroadcastIsIgnored() {
        // A command that started earlier belongs to whatever came before;
        // attributing it would report a stale status as this run's.
        var run = makeRun(command: "uptime")
        run.record(
            event: event(command: "uptime", started: start - 5, finished: start - 1, exit: 0),
            from: hostA
        )
        XCTAssertEqual(result(run, hostA).outcome, .awaitingReport)
    }

    func testAnUnnamedCommandIsMatchedByTimingAndLabelledAsSuch() {
        // bash's DEBUG trap can't always supply the command text. The timing
        // still places it after the broadcast, but that is a weaker claim and
        // the row has to say so rather than presenting it as confirmed.
        var run = makeRun(command: "uptime")
        run.record(
            event: event(command: "", started: start + 1, finished: start + 2, exit: 0),
            from: hostA
        )
        XCTAssertEqual(
            result(run, hostA).outcome,
            .finished(exitCode: 0, at: start + 2, attribution: .timingOnly)
        )
        XCTAssertTrue(result(run, hostA).label.contains("matched by timing"))
    }

    func testAMissingExitStatusIsNotReportedAsZero() {
        var run = makeRun(command: "uptime")
        run.record(
            event: event(command: "uptime", started: start + 1, finished: start + 2, exit: nil),
            from: hostA
        )
        XCTAssertNil(result(run, hostA).exitCode)
        XCTAssertTrue(result(run, hostA).label.contains("not reported"))
    }

    // MARK: - Settled results stay put

    func testASettledResultIsNotOverwrittenByLaterActivity() {
        // The user keeps working in the pane afterwards. Those commands are
        // not this broadcast, and must not rewrite its recorded outcome.
        var run = makeRun(command: "uptime")
        run.record(
            event: event(command: "uptime", started: start + 1, finished: start + 2, exit: 0),
            from: hostA
        )
        run.record(
            event: event(command: "rm -rf /tmp/x", started: start + 9, finished: start + 10, exit: 1),
            from: hostA
        )
        XCTAssertEqual(result(run, hostA).exitCode, 0, "the recorded outcome is the broadcast's")
    }

    func testAnEventForAHostNotInTheRunIsIgnored() {
        var run = makeRun(command: "uptime")
        let stranger = UUID()
        run.record(
            event: event(command: "uptime", started: start + 1, finished: start + 2, exit: 0),
            from: stranger
        )
        XCTAssertEqual(run.results.count, 2)
        XCTAssertTrue(run.results.allSatisfy { $0.outcome == .awaitingReport })
    }

    func testAHostReportingForTheFirstTimeUpgradesOutOfUnobservable() {
        // "Unobservable" is a statement about what this host has done before,
        // not a promise about the future. A host whose shell integration was
        // just installed reports on its first command, and that report is
        // real — refusing it would permanently mislabel the host.
        var run = BroadcastRun(
            command: "uptime", startedAt: start,
            results: [
                BroadcastResult(
                    sessionID: hostA, host: "fresh-box",
                    outcome: .unobservable(reason: "This host hasn't reported command results.")
                )
            ]
        )
        run.record(
            event: event(command: "uptime", started: start + 1, finished: start + 2, exit: 0),
            from: hostA
        )
        XCTAssertEqual(result(run, hostA).exitCode, 0)
    }

    // MARK: - Summary

    func testTheSummaryCountsWhatWasObservedNotWhatWasSent() {
        var run = BroadcastRun(
            command: "uptime", startedAt: start,
            results: [
                BroadcastResult(sessionID: hostA, host: "a", outcome: .awaitingReport),
                BroadcastResult(sessionID: hostB, host: "b", outcome: .awaitingReport),
                BroadcastResult(
                    sessionID: UUID(), host: "c",
                    outcome: .unobservable(reason: "This host doesn't report command results.")
                )
            ]
        )
        run.record(
            event: event(command: "uptime", started: start + 1, finished: start + 2, exit: 1),
            from: hostA
        )
        let summary = run.summary
        XCTAssertTrue(summary.contains("1 of 3 reported"), summary)
        XCTAssertTrue(summary.contains("1 non-zero"), summary)
        XCTAssertTrue(summary.contains("1 cannot report"), summary)
    }

    // MARK: - Helpers

    private func makeRun(command: String) -> BroadcastRun {
        BroadcastRun(
            command: command, startedAt: start,
            results: [
                BroadcastResult(sessionID: hostA, host: "host-a", outcome: .awaitingReport),
                BroadcastResult(sessionID: hostB, host: "host-b", outcome: .awaitingReport)
            ]
        )
    }

    private func event(
        command: String, started: Date, finished: Date?, exit: Int?
    ) -> CommandEvent {
        CommandEvent(
            command: command, startedAt: started, finishedAt: finished, exitCode: exit
        )
    }

    private func result(_ run: BroadcastRun, _ session: UUID) -> BroadcastResult {
        run.results.first { $0.sessionID == session }!
    }
}
