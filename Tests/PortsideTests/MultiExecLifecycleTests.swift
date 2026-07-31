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

    // MARK: - Disarm reasons

    func testEveryDisarmReasonExplainsItself() {
        // The banner vanishing is the signal that something changed; it's only
        // useful if followed by what. A reason that can't say why it disarmed
        // isn't a good enough reason to disarm.
        let reasons: [MultiExecDisarmReason] = [.systemWoke]
        for reason in reasons {
            XCTAssertTrue(reason.message.contains("MultiExec disarmed"),
                          "\(reason) must name what happened")
            XCTAssertGreaterThan(reason.message.count, 40,
                                 "\(reason) must say why, not just that")
        }
    }
}
