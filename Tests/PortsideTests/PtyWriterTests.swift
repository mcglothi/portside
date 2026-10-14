import Darwin
import XCTest
@testable import Portside

/// Portside writes pty input itself rather than through SwiftTerm 2's
/// LocalProcess.send, whose writes never completed on macOS 15 (#73).
final class PtyWriterTests: XCTestCase {
    private var master: Int32 = -1, slave: Int32 = -1

    override func setUp() {
        super.setUp()
        XCTAssertEqual(openpty(&master, &slave, nil, nil, nil), 0)
        // Raw, so the slave reads exactly the bytes written.
        var t = termios()
        tcgetattr(slave, &t)
        cfmakeraw(&t)
        tcsetattr(slave, TCSANOW, &t)
    }

    override func tearDown() {
        close(master); close(slave)
        super.tearDown()
    }

    private func read(_ count: Int, timeout: TimeInterval = 5) -> [UInt8] {
        var out: [UInt8] = []
        let deadline = Date().addingTimeInterval(timeout)
        var buf = [UInt8](repeating: 0, count: 65536)
        while out.count < count, Date() < deadline {
            var p = pollfd(fd: slave, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 100) > 0 else { continue }
            let n = Darwin.read(slave, &buf, buf.count)
            if n > 0 { out += buf[..<n] }
        }
        return out
    }

    func testWritesArriveInOrder() {
        let w = PtyWriter()
        w.attach(master)
        for i in 0..<50 { XCTAssertTrue(w.write(Array("k\(i),".utf8)[...])) }
        let expected = Array((0..<50).map { "k\($0)," }.joined().utf8)
        XCTAssertEqual(read(expected.count), expected)
    }

    /// More than a pty holds at once: the writer waits for the reader rather
    /// than dropping or blocking its caller.
    func testALargeWriteCompletesAsTheOtherSideReads() {
        let w = PtyWriter()
        w.attach(master)
        let big = (0..<300_000).map { UInt8(truncatingIfNeeded: $0 % 251 + 1) }
        let start = Date()
        XCTAssertTrue(w.write(big[...]))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5, "the caller doesn't wait for the pty")
        XCTAssertEqual(read(big.count, timeout: 10), big)
    }

    func testNothingIsWrittenOnceDetached() {
        let w = PtyWriter()
        XCTAssertFalse(w.write(Array("x".utf8)[...]), "not attached: the caller falls back")
        w.attach(master)
        w.detach()
        XCTAssertFalse(w.write(Array("late".utf8)[...]))
        XCTAssertEqual(read(1, timeout: 0.5), [])
    }
}
