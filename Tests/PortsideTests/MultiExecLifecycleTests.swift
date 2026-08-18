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

    // MARK: - Line endings
    //
    // These exist because a two-command CRLF paste was **sent to every pane
    // with no confirmation**, while the identical paste with LF endings was
    // correctly held. `\r\n` is a single Swift `Character`, so the old
    // `split(separator: "\n")` found no separator in CRLF text and reported one
    // line. Clipboards from Windows, RDP, browsers and Excel are all CRLF, so
    // the bypass was reachable by ordinary copy-and-paste.

    func testACRLFMultiCommandPasteIsConfirmed() {
        let text = "cd /var/log\r\nrm -rf ./*\r\nsystemctl restart nginx"
        guard case .confirm(let lines, _) = BroadcastPasteReview.review(text: text, targetCount: 4) else {
            return XCTFail("a CRLF multi-command paste must be confirmed like any other")
        }
        XCTAssertEqual(lines, 3)
    }

    /// The one that was actually broken in the field: short enough to miss the
    /// size threshold, so line counting was the only thing standing between it
    /// and every pane.
    func testAShortCRLFPasteCannotSlipUnderTheSizeThreshold() {
        let text = "rm -rf /var/log/app\r\nsystemctl restart nginx\r\n"
        XCTAssertLessThan(text.count, BroadcastPasteReview.largePasteThreshold,
                          "this test is only meaningful below the size threshold")
        guard case .confirm(let lines, _) = BroadcastPasteReview.review(text: text, targetCount: 12) else {
            return XCTFail("two CRLF commands across 12 panes must be confirmed")
        }
        XCTAssertEqual(lines, 2)
    }

    /// Line endings must not change the verdict, whichever convention the
    /// clipboard used.
    func testEveryLineEndingReachesTheSameVerdict() {
        let commands = ["cd /var/log", "rm -rf ./*"]
        for (name, terminator) in [("LF", "\n"), ("CRLF", "\r\n"), ("CR", "\r")] {
            let text = commands.joined(separator: terminator)
            guard case .confirm(let lines, _) = BroadcastPasteReview.review(text: text,
                                                                           targetCount: 4) else {
                XCTFail("\(name): two commands must be confirmed")
                continue
            }
            XCTAssertEqual(lines, 2, "\(name): wrong line count")
        }
    }

    /// A trailing CRLF is a terminator, exactly as a trailing LF is — so a
    /// genuine one-command paste must still not nag.
    func testATrailingCRLFIsStillOneCommand() {
        XCTAssertEqual(BroadcastPasteReview.review(text: "systemctl restart nginx\r\n",
                                                   targetCount: 8), .send,
                       "a single trailing CRLF is a terminator, not a second command")
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
