import XCTest
@testable import Portside

/// Until 0.25, `processTerminated` took the child's exit status and discarded
/// it, and the bar under a dead pane said "Session ended" for every ending.
/// These lock in that the endings people actually hit are told apart, and —
/// just as importantly — that an ending we cannot read says so instead of
/// being filed under whichever cause happens to be first.
final class ConnectionDiagnosisTests: XCTestCase {

    // MARK: - The endings worth telling apart

    func testAcleanExitIsNotAFailure() {
        let reading = diagnose("logout\nConnection to babbage closed.\n", exit: 0)
        XCTAssertEqual(reading.cause, .exitedNormally)
        XCTAssertFalse(reading.isFailure)
        XCTAssertNil(reading.nextStep, "a normal exit has no next step to suggest")
    }

    func testAnUnresolvableNameIsReportedAsDNS() {
        let reading = diagnose(
            "ssh: Could not resolve hostname babbge: nodename nor servname provided\n", exit: 255
        )
        XCTAssertEqual(reading.cause, .hostNotFound)
        XCTAssertTrue(reading.isFailure)
    }

    func testATimeoutIsNotConfusedWithARefusal() {
        XCTAssertEqual(
            diagnose("ssh: connect to host babbage port 22: Operation timed out\n", exit: 255).cause,
            .timedOut
        )
        XCTAssertEqual(
            diagnose("ssh: connect to host babbage port 22: Connection refused\n", exit: 255).cause,
            .connectionRefused
        )
    }

    func testNoRouteIsItsOwnCause() {
        XCTAssertEqual(
            diagnose("ssh: connect to host 10.0.0.9 port 22: No route to host\n", exit: 255).cause,
            .networkUnreachable
        )
    }

    func testAuthenticationFailureIsReportedAsCredentials() {
        XCTAssertEqual(
            diagnose("tim@babbage: Permission denied (publickey,password).\n", exit: 255).cause,
            .authenticationFailed
        )
    }

    func testTooManyAuthFailuresIsSeparateFromAPlainRejection() {
        // Different next step: the account is at risk of lockout, and the fix
        // is to stop offering every key rather than to check the password.
        let reading = diagnose(
            "Received disconnect from 10.0.0.4 port 22:2: Too many authentication failures\n",
            exit: 255
        )
        XCTAssertEqual(reading.cause, .tooManyAuthFailures)
        XCTAssertTrue(reading.nextStep?.contains("lock an account out") == true)
    }

    // MARK: - Host key

    func testAchangedHostKeyWinsOverTheVerificationFailureItAlsoPrints() {
        // ssh prints both, and the changed-key warning is the reading that
        // matters. Matching on whichever appears first in the list would file
        // a possible interception under "just accept the fingerprint".
        let output = """
            @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
            @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
            @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
            IT IS POSSIBLE THAT SOMEONE IS DOING SOMETHING NASTY!
            Host key verification failed.
            """
        let reading = diagnose(output, exit: 255)
        XCTAssertEqual(reading.cause, .hostKeyChanged)
        XCTAssertTrue(reading.nextStep?.contains("ssh-keygen -R") == true)
    }

    func testAnUnverifiedHostKeyOnItsOwnIsTheMilderReading() {
        XCTAssertEqual(
            diagnose("Host key verification failed.\n", exit: 255).cause, .hostKeyUnverified
        )
    }

    // MARK: - Honesty about what it does not know

    func testAnUnrecognisedSSHFailureSaysSoRatherThanGuessing() {
        let reading = diagnose("ssh: something nobody has seen before\n", exit: 255)
        XCTAssertEqual(reading.cause, .unknown(255))
        XCTAssertTrue(reading.headline.contains("could not connect"))
    }

    func testANonZeroRemoteStatusIsReportedAsTheRemoteCommandsOwn() {
        // Not an ssh failure: ssh passes the remote command's status through,
        // so 130 here is the far end being interrupted, not a connection fault.
        let reading = diagnose("^C\n", exit: 130)
        XCTAssertEqual(reading.cause, .remoteCommandFailed(130))
        XCTAssertNil(reading.nextStep, "we have nothing general to suggest for a remote status")
    }

    func testEveryFailureCarriesTheLineItReadIt() {
        // The classifier is a heuristic over English messages. Showing the
        // evidence is what makes being wrong cheap rather than misleading.
        let cases = [
            "ssh: Could not resolve hostname nope: Name or service not known",
            "ssh: connect to host h port 22: Connection refused",
            "tim@h: Permission denied (publickey).",
            "Host key verification failed."
        ]
        for line in cases {
            let reading = diagnose(line + "\n", exit: 255)
            XCTAssertEqual(
                reading.evidence, line,
                "the diagnosis for \(line) should quote the line it matched"
            )
        }
    }

    // MARK: - Not every transport is ssh

    func testASerialConsoleIsNotDiagnosedWithSSHMessages() {
        // A serial session that happens to print "Connection refused" from
        // something running on the far end is not an ssh connection failure.
        let reading = ConnectionDiagnosis.diagnose(
            output: "app: Connection refused\n", exitCode: 0, kind: .serial
        )
        XCTAssertEqual(reading.cause, .exitedNormally)
    }

    // MARK: - Reading the right ending

    func testTheMostRecentMessageWins() {
        // A long session can scroll an unrelated failure past on its way to a
        // real one; the ending being explained is the last thing that happened.
        let output = """
            ssh: connect to host old port 22: Connection refused
            Retrying...
            tim@new: Permission denied (publickey).
            """
        XCTAssertEqual(diagnose(output, exit: 255).cause, .authenticationFailed)
    }

    func testEscapeSequencesDoNotHideTheMessage() {
        // The tail is captured from the pty, so it arrives with SGR colouring
        // around it. strippingEscapes runs on the way in; this asserts the
        // pairing actually works end to end.
        let coloured = "\u{1B}[31mssh: connect to host h port 22: Connection refused\u{1B}[0m\n"
        let plain = LoggingTerminalView.strippingEscapes(coloured)
        XCTAssertFalse(plain.contains("\u{1B}"))
        let reading = ConnectionDiagnosis.diagnose(output: plain, exitCode: 255, kind: .host)
        XCTAssertEqual(reading.cause, .connectionRefused)
        XCTAssertEqual(
            reading.evidence, "ssh: connect to host h port 22: Connection refused",
            "the quoted evidence must not carry escape sequences into the UI"
        )
    }

    func testOSCSequencesAreStrippedToo() {
        let titled = "\u{1B}]0;tim@babbage\u{07}Permission denied (publickey).\n"
        let plain = LoggingTerminalView.strippingEscapes(titled)
        XCTAssertEqual(plain, "Permission denied (publickey).\n")
    }

    // MARK: - The tail is bounded

    func testTheOutputTailKeepsOnlyTheEnd() {
        // A session can run for a week. Keeping its whole output to explain
        // one ending would be a slow leak with no upper bound.
        let tail = OutputTail(limit: 32)
        tail.append(String(repeating: "x", count: 100))
        tail.append("Permission denied (publickey).")
        XCTAssertEqual(tail.current.count, 32)
        XCTAssertTrue(
            tail.current.hasSuffix("Permission denied (publickey)."),
            "the most recent output is the part worth keeping"
        )
    }

    func testAShortSessionKeepsEverythingItPrinted() {
        let tail = OutputTail(limit: 32)
        tail.append("short\n")
        XCTAssertEqual(tail.current, "short\n")
    }

    // MARK: - Helpers

    private func diagnose(_ output: String, exit: Int32?) -> ConnectionDiagnosis {
        ConnectionDiagnosis.diagnose(output: output, exitCode: exit, kind: .host)
    }
}
