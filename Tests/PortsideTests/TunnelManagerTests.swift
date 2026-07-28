import Foundation
import XCTest
@testable import Portside

/// `TunnelManager` used to only read a tunnel's stderr pipe after the process
/// had already exited. A pipe's OS buffer is a fixed, small size (tens of KB);
/// enough diagnostic output — a chatty ProxyCommand, a verbose motd some
/// servers relay — fills it, blocks the child's write(), and since nothing
/// was reading, it never exits: a tunnel that can't be torn down. These
/// exercise the fix (continuous draining via `PipeDrain` +
/// `readabilityHandler`) directly, since `TunnelManager` itself always
/// launches `/usr/bin/ssh` and can't be pointed at a stub binary.
final class TunnelManagerTests: XCTestCase {

    func testPipeDrainAccumulatesAppendedChunks() {
        let drain = PipeDrain()
        drain.append(Data("hello ".utf8))
        drain.append(Data("world".utf8))
        XCTAssertEqual(String(data: drain.collected, encoding: .utf8), "hello world")
    }

    func testPipeDrainIsSafeUnderConcurrentAppends() {
        let drain = PipeDrain()
        let chunk = Data(repeating: 0x41, count: 1_024)
        let iterations = 200
        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            drain.append(chunk)
        }
        XCTAssertEqual(drain.collected.count, iterations * chunk.count)
    }

    /// Reproduces the deadlock scenario end to end against a real child
    /// process: a shell command that writes several megabytes to stderr —
    /// several times a typical pipe buffer — using exactly the drain pattern
    /// `TunnelManager.start` now uses. Without continuous draining, this
    /// would hang until the test's own timeout; with it, the child runs to
    /// completion because its writes are never blocked.
    func testContinuousDrainingPreventsAPipeBufferDeadlock() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // ~4MB to stderr — comfortably past any OS pipe buffer size. Order
        // matters: `>&2` first duplicates stdout onto the real stderr (our
        // pipe) *before* `2>/dev/null` repoints fd2 to swallow dd's own
        // progress summary — the dup already happened, so fd1 keeps going
        // to the pipe.
        process.arguments = ["-c", "dd if=/dev/zero bs=65536 count=64 >&2 2>/dev/null"]
        let errPipe = Pipe()
        let outPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = outPipe

        let drain = PipeDrain()
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { drain.append(chunk) }
        }
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }

        let finished = expectation(description: "process exited without deadlocking")
        process.terminationHandler = { _ in finished.fulfill() }

        try process.run()
        wait(for: [finished], timeout: 10)

        errPipe.fileHandleForReading.readabilityHandler = nil
        outPipe.fileHandleForReading.readabilityHandler = nil
        XCTAssertGreaterThan(drain.collected.count, 0, "drained output should be non-empty")
    }
}
