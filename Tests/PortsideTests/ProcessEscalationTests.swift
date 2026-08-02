import XCTest
@testable import Portside

/// That a process ignoring SIGTERM is still stopped.
///
/// A tunnel is `ssh -N` holding a local port. If it sits through SIGTERM —
/// wedged mid-handshake, or blocked on a ProxyCommand that is itself stuck —
/// then Portside believes it stopped the tunnel while the port stays bound, the
/// next start fails with "address already in use", and nothing on screen
/// explains why. The only way out is Activity Monitor.
///
/// Tested against a real process that genuinely ignores SIGTERM, because the
/// escalation is worthless if it only works on processes that would have
/// exited anyway.
final class ProcessEscalationTests: XCTestCase {

    /// A shell that traps SIGTERM and keeps running — a stand-in for a wedged
    /// ssh, and unkillable by `terminate()` alone.
    private func makeStubbornProcess() -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; while :; do sleep 0.1; done"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    /// Starts it and waits for the trap to actually be installed.
    ///
    /// Signalling straight after `run()` catches the shell before it has parsed
    /// `trap`, so the default action applies and the "stubborn" process dies on
    /// SIGTERM — which made this suite pass for entirely the wrong reason.
    private func runAndSettle(_ process: Process) throws {
        try process.run()
        usleep(400_000)
    }

    private func waitForExit(_ process: Process, upTo seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !process.isRunning { return true }
            usleep(20_000)
        }
        return !process.isRunning
    }

    func testSIGTERMAloneDoesNotStopAStubbornProcess() throws {
        // Establishes that the stand-in is actually stubborn — otherwise the
        // escalation test below would pass for the wrong reason.
        let process = makeStubbornProcess()
        try runAndSettle(process)
        defer { if process.isRunning { kill(-process.processIdentifier, SIGKILL) } }

        process.terminate()

        XCTAssertFalse(waitForExit(process, upTo: 0.6),
                       "the stand-in should survive SIGTERM, or this suite proves nothing")
    }

    func testKillingTheProcessGroupStopsIt() throws {
        let process = makeStubbornProcess()
        try runAndSettle(process)

        process.terminate()
        _ = waitForExit(process, upTo: 0.3)
        XCTAssertTrue(process.isRunning, "still up after SIGTERM, as expected")

        // The escalation TunnelManager performs.
        let pid = process.processIdentifier
        if kill(pid, 0) == 0 { kill(-pid, SIGKILL) }

        XCTAssertTrue(waitForExit(process, upTo: 2),
                      "SIGKILL to the process group must stop it")
    }

    func testKillingTheGroupAlsoTakesChildrenWithIt() throws {
        // Why the group and not just the pid: a ProxyCommand is a child of ssh
        // and would otherwise keep running — and keep holding whatever it had
        // open — after its parent is gone.
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/sh")
        parent.arguments = ["-c", "sh -c 'while :; do sleep 0.1; done' & trap '' TERM; wait"]
        parent.standardOutput = FileHandle.nullDevice
        parent.standardError = FileHandle.nullDevice
        try runAndSettle(parent)
        let pid = parent.processIdentifier

        kill(-pid, SIGKILL)

        XCTAssertTrue(waitForExit(parent, upTo: 2))
        // The child was in the same group, so it went too. If it hadn't, it
        // would still be reachable by group signal.
        XCTAssertEqual(kill(-pid, 0), -1, "nothing should remain in the group")
    }
}
