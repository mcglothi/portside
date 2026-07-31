import XCTest
@testable import Portside

/// The armed broadcast's lifecycle rules: when it comes down on its own, and
/// when a paste into it has to be confirmed first.
final class MultiExecLifecycleTests: XCTestCase {

    // MARK: - Paste review

    func testAnOrdinarySingleCommandPasteIsNotNagged() {
        // The shape of almost every useful paste. Prompting here would train
        // the confirmation away, which costs more than it saves.
        XCTAssertEqual(BroadcastPasteReview.review(text: "systemctl restart nginx", targetCount: 8), .send)
        XCTAssertEqual(BroadcastPasteReview.review(text: "systemctl restart nginx\n", targetCount: 8), .send,
                       "a single trailing newline is still one command")
    }

    func testMultipleCommandsAreConfirmed() {
        let text = "cd /var/log\nrm -rf ./*\nsystemctl restart nginx"
        guard case .confirm(let lines, _) = BroadcastPasteReview.review(text: text, targetCount: 4) else {
            return XCTFail("a multi-command paste across 4 hosts must be confirmed")
        }
        XCTAssertEqual(lines, 3)
    }

    func testATrailingNewlineDoesNotInflateTheLineCount() {
        guard case .confirm(let lines, _) = BroadcastPasteReview.review(text: "one\ntwo\n", targetCount: 2) else {
            return XCTFail("two commands must be confirmed")
        }
        XCTAssertEqual(lines, 2, "the trailing newline is a terminator, not an empty third command")
    }

    func testABlankLineInTheMiddleStillCounts() {
        // Pasting a snippet with a blank line between commands is still a
        // multi-command paste; the blank just runs as an empty prompt.
        guard case .confirm = BroadcastPasteReview.review(text: "one\n\ntwo", targetCount: 2) else {
            return XCTFail("interior blank lines don't make this one command")
        }
    }

    func testALargeSingleLinePasteIsConfirmed() {
        // No newline at all, but nobody means to run 600 characters of
        // something on every host.
        let blob = String(repeating: "A", count: BroadcastPasteReview.largePasteThreshold + 1)
        guard case .confirm(let lines, let chars) = BroadcastPasteReview.review(text: blob, targetCount: 3) else {
            return XCTFail("a large paste must be confirmed on shape alone")
        }
        XCTAssertEqual(lines, 1)
        XCTAssertEqual(chars, BroadcastPasteReview.largePasteThreshold + 1)
    }

    func testAPasteJustUnderTheThresholdIsStillSent() {
        let blob = String(repeating: "A", count: BroadcastPasteReview.largePasteThreshold)
        XCTAssertEqual(BroadcastPasteReview.review(text: blob, targetCount: 3), .send)
    }

    func testASinglePaneIsNeverConfirmed() {
        // Not broadcasting: this is the operator's own session, and a
        // confirmation here is pure friction.
        let text = "cd /var/log\nrm -rf ./*"
        XCTAssertEqual(BroadcastPasteReview.review(text: text, targetCount: 1), .send)
        XCTAssertEqual(BroadcastPasteReview.review(text: text, targetCount: 0), .send)
    }

    func testTheDangerousPasteFromTheReviewIsCaught() {
        // The failure mode this exists for: a half-copied runbook going to
        // every included host at once.
        let runbook = """
        sudo systemctl stop app
        rm -rf /var/lib/app/cache
        sudo systemctl start app
        """
        guard case .confirm(let lines, _) = BroadcastPasteReview.review(text: runbook, targetCount: 12) else {
            return XCTFail("this is precisely the paste that must be confirmed")
        }
        XCTAssertEqual(lines, 3)
    }

    func testAReconnectedHostIsNamedButALocalShellIsNot() {
        // With twelve panes, "a pane reconnected" is not actionable — so name
        // it when there's a name. An entry-less pane has only its title, which
        // OSC sets to the last command, so naming that produced the nonsense
        // "exit reconnected" after a shell was exited.
        XCTAssertTrue(MultiExecDisarmReason.paneReconnected(host: "web-03")
            .message.contains("web-03"))
        XCTAssertTrue(MultiExecDisarmReason.paneReconnected(host: nil)
            .message.contains("a pane reconnected"))
    }

    // MARK: - Target list

    @MainActor
    private func sessions(named names: [String?]) -> [TerminalSession] {
        names.map { name in
            guard let name else { return TerminalSession(title: "local", executable: "/bin/echo", args: []) }
            let entry = SessionEntry(name: name, folder: "", hostname: "\(name).example.com")
            return TerminalSession(title: name, executable: "/bin/echo", args: [], entry: entry)
        }
    }

    @MainActor
    func testRepeatedTargetsCollapseWithACount() {
        // A grid of local shells listed the same string a dozen times, which
        // reads as noise and hides the one entry that might differ.
        let list = SessionManager.targetList(sessions(named: [nil, nil, nil]))
        XCTAssertEqual(list, "local shell ×3")
    }

    @MainActor
    func testDistinctHostsAreAllNamedInGridOrder() {
        let list = SessionManager.targetList(sessions(named: ["web-01", "web-02", "db-01"]))
        XCTAssertEqual(list, "web-01, web-02, db-01")
    }

    @MainActor
    func testAMixedGridNamesHostsAndCollapsesTheRest() {
        let list = SessionManager.targetList(sessions(named: ["web-01", nil, nil]))
        XCTAssertEqual(list, "web-01, local shell ×2",
                       "the named host must stay visible next to the collapsed shells")
    }

    @MainActor
    func testAVeryLongListIsTruncatedSoTheButtonsStayOnScreen() {
        let many = (1...20).map { Optional("host-\($0)") }
        let list = SessionManager.targetList(sessions(named: many), limit: 12)
        XCTAssertTrue(list.hasSuffix("and 8 more"), "got: \(list)")
        XCTAssertTrue(list.hasPrefix("host-1, host-2"))
    }

    // MARK: - Network change

    func testTheFirstPathIsABaselineNotAChange() {
        // Disarming on the first callback would take the group down on every
        // launch, and on every re-arm that happens to race one.
        XCTAssertFalse(NetworkChangeDecision.shouldDisarm(
            previous: nil, current: ["en0"], satisfied: true))
    }

    func testMovingBetweenInterfacesDisarms() {
        // The hazard: off the VPN, `prod-db` resolves somewhere else, but the
        // established connections look untouched.
        XCTAssertTrue(NetworkChangeDecision.shouldDisarm(
            previous: ["utun3", "en0"], current: ["en0"], satisfied: true))
        XCTAssertTrue(NetworkChangeDecision.shouldDisarm(
            previous: ["en0"], current: ["en1"], satisfied: true))
    }

    func testTheSameInterfacesAreNotAChange() {
        // NWPathMonitor fires for flag changes (expensive, constrained) with
        // no move at all. Those must not disarm.
        XCTAssertFalse(NetworkChangeDecision.shouldDisarm(
            previous: ["en0"], current: ["en0"], satisfied: true))
    }

    func testAnUnsatisfiedPathWaitsRatherThanDisarming() {
        // A gap on the way back to the same network is not a move. Disarming
        // on it would fire on every brief drop — exactly the noise that trains
        // people to ignore a guardrail.
        XCTAssertFalse(NetworkChangeDecision.shouldDisarm(
            previous: ["en0"], current: [], satisfied: false))
        XCTAssertFalse(NetworkChangeDecision.shouldDisarm(
            previous: ["en0"], current: ["utun3"], satisfied: false))
    }

    func testInterfaceOrderIsNotAChange() {
        // Set comparison, so the order the OS reports them in can't matter.
        XCTAssertFalse(NetworkChangeDecision.shouldDisarm(
            previous: ["en0", "utun3"], current: ["utun3", "en0"], satisfied: true))
    }

    // MARK: - Disarm reasons

    func testEveryDisarmReasonExplainsItself() {
        // The banner vanishing is the signal that something changed; it's only
        // useful if followed by what. A reason that can't say why it disarmed
        // isn't a good enough reason to disarm.
        let reasons: [MultiExecDisarmReason] = [
            .paneReconnected(host: "web-03"), .paneReconnected(host: nil),
            .networkChanged, .systemWoke,
        ]
        for reason in reasons {
            XCTAssertTrue(reason.message.contains("MultiExec disarmed"),
                          "\(reason) must name what happened")
            XCTAssertGreaterThan(reason.message.count, 40,
                                 "\(reason) must say why, not just that")
        }
    }
}
