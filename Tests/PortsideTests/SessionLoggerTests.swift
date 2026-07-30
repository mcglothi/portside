import Foundation
import XCTest
@testable import Portside

/// `ANSIStripper` runs over the raw session stream and decides what reaches the
/// transcript. It holds state across chunk boundaries, which is necessary — a
/// sequence can straddle a read — but it also means a sequence the stripper
/// never considers finished swallows every byte that follows it, for the rest
/// of the session, with nothing in the log to say why.
///
/// These cover the exits rather than the entries: cancellation controls, both
/// spellings of ST, the runaway ceiling, and the chunk boundaries where a
/// stateful parser is easiest to get wrong.
final class ANSIStripperTests: XCTestCase {

    private func strip(_ input: [UInt8]) -> String {
        var stripper = ANSIStripper()
        return String(decoding: stripper.strip(input), as: UTF8.self)
    }

    private func strip(_ input: String) -> String {
        strip(Array(input.utf8))
    }

    // MARK: - Baseline

    func testPlainTextPassesThrough() {
        XCTAssertEqual(strip("hello world\n"), "hello world\n")
    }

    func testColourSequencesAreStripped() {
        XCTAssertEqual(strip("\u{1B}[31mred\u{1B}[0m\n"), "red\n")
    }

    func testTerminatedOSCIsStrippedAndOutputResumes() {
        XCTAssertEqual(strip("\u{1B}]0;a title\u{07}after\n"), "after\n")
    }

    // MARK: - Cancellation controls

    /// CAN (0x18) and SUB (0x1A) abort a sequence in flight. A terminal that
    /// honours them stops interpreting; a stripper that ignores them stays in
    /// the sequence and disagrees with the screen from that point on.
    func testCANAbortsSequenceInFlight() {
        XCTAssertEqual(strip("\u{1B}]0;partial\u{18}visible\n"), "visible\n")
    }

    func testSUBAbortsSequenceInFlight() {
        XCTAssertEqual(strip("\u{1B}]0;partial\u{1A}visible\n"), "visible\n")
    }

    func testCANAbortsFromCSIAndDCSToo() {
        XCTAssertEqual(strip("\u{1B}[38;5\u{18}visible\n"), "visible\n")
        XCTAssertEqual(strip("\u{1B}Pq#0;2;0\u{18}visible\n"), "visible\n")
    }

    /// A bare CAN in ordinary output is a control character and stays dropped.
    func testCANInNormalTextIsStillDropped() {
        XCTAssertEqual(strip("a\u{18}b\n"), "ab\n")
    }

    // MARK: - String terminators

    func testOSCTerminatedByESCBackslash() {
        XCTAssertEqual(strip("\u{1B}]0;title\u{1B}\\after\n"), "after\n")
    }

    /// 0x9C is the C1 spelling of ST. Without it, a terminal emitting 8-bit
    /// controls left the stripper in `.osc` permanently.
    func testOSCTerminatedByC1ST() {
        XCTAssertEqual(strip([0x1B, 0x5D] + Array("0;t".utf8) + [0x9C] + Array("after\n".utf8)), "after\n")
    }

    func testDCSTerminatedByC1ST() {
        XCTAssertEqual(strip([0x1B, 0x50] + Array("q#0".utf8) + [0x9C] + Array("after\n".utf8)), "after\n")
    }

    /// SOS, PM and APC are ST-terminated strings. They previously fell through
    /// the two-byte-escape default, so only the introducer was swallowed and
    /// the body was emitted as if it were text.
    func testAPCBodyIsNotEmittedAsText() {
        XCTAssertEqual(strip("\u{1B}_secret payload\u{1B}\\visible\n"), "visible\n")
    }

    func testPMAndSOSBodiesAreNotEmittedAsText() {
        XCTAssertEqual(strip("\u{1B}^privacy\u{1B}\\ok\n"), "ok\n")
        XCTAssertEqual(strip("\u{1B}Xstatus\u{1B}\\ok\n"), "ok\n")
    }

    // MARK: - Chunk boundaries

    /// The state machine's whole reason for existing. Split at every position
    /// and confirm the result never depends on where the read landed.
    func testResultIsIndependentOfChunkBoundaries() {
        let input = Array("before\u{1B}]0;title\u{07}middle\u{1B}[1;32mgreen\u{1B}[0mafter\n".utf8)
        let expected = "beforemiddlegreenafter\n"
        for split in 0...input.count {
            var stripper = ANSIStripper()
            let a = stripper.strip(Array(input[..<split]))
            let b = stripper.strip(Array(input[split...]))
            XCTAssertEqual(
                String(decoding: a + b, as: UTF8.self), expected,
                "mismatch when split at \(split)"
            )
        }
    }

    /// ESC and its terminator landing in different chunks is the case a
    /// stateless stripper gets wrong.
    func testTerminatorSplitAcrossChunks() {
        var stripper = ANSIStripper()
        let a = stripper.strip(Array("\u{1B}]0;title\u{1B}".utf8))
        let b = stripper.strip(Array("\\after\n".utf8))
        XCTAssertEqual(String(decoding: a + b, as: UTF8.self), "after\n")
    }

    // MARK: - Runaway ceiling

    /// An OSC that never terminates must not consume the session. Past the
    /// ceiling the stripper gives up and resumes emitting.
    func testUnterminatedSequenceRecoversAtCeiling() {
        var stripper = ANSIStripper()
        _ = stripper.strip(Array("\u{1B}]0;".utf8))
        // Feed past the ceiling in chunks, mimicking a real stream.
        let filler = [UInt8](repeating: 0x41, count: 64 << 10)
        var fed = 0
        while fed <= ANSIStripper.maxSequenceLength {
            _ = stripper.strip(filler)
            fed += filler.count
        }
        let tail = String(decoding: stripper.strip(Array("recovered\n".utf8)), as: UTF8.self)
        XCTAssertEqual(tail, "recovered\n")
    }

    /// The ceiling must not fire on legitimately large payloads — Portside
    /// renders inline images, and a Sixel or OSC 1337 screenshot is megabytes.
    func testLargeButTerminatedPayloadIsStillStripped() {
        var stripper = ANSIStripper()
        _ = stripper.strip(Array("\u{1B}]1337;File=inline=1:".utf8))
        let payload = [UInt8](repeating: 0x41, count: 1 << 20)   // 1 MiB, under the ceiling
        let mid = stripper.strip(payload)
        XCTAssertTrue(mid.isEmpty, "payload under the ceiling should be swallowed, not emitted")
        let tail = String(decoding: stripper.strip(Array("\u{07}after\n".utf8)), as: UTF8.self)
        XCTAssertEqual(tail, "after\n")
    }
}

/// `close()` writes the footer from a block on the logger's own serial queue.
/// It used to capture `self` weakly, so a caller releasing its reference in the
/// same turn — a tab closing takes `SessionManager` and its logger with it —
/// could leave the block with nothing to run against, dropping the footer and
/// any queued output behind it.
final class SessionLoggerLifecycleTests: XCTestCase {

    private func makeTempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-logger-test-\(UUID().uuidString)")
            .appendingPathComponent("session.log")
    }

    /// Release the only reference immediately after `close()` and confirm the
    /// transcript is still complete on disk.
    func testFooterSurvivesImmediateDeallocation() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        autoreleasepool {
            let logger = SessionLogger(fileURL: url, title: "web-01", subtitle: "")
            XCTAssertNotNil(logger)
            logger?.append(ArraySlice(Array("output line\n".utf8)))
            logger?.close()
            // logger goes out of scope here, while the queue may still be
            // working through both blocks.
        }

        // Give the serial queue a moment to drain; the strong capture is what
        // guarantees there is still an object for it to drain into.
        let deadline = Date().addingTimeInterval(2)
        var contents = ""
        while Date() < deadline {
            contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if contents.contains("session ended") { break }
            usleep(20_000)
        }

        XCTAssertTrue(contents.contains("output line"), "queued append was dropped:\n\(contents)")
        XCTAssertTrue(contents.contains("session ended"), "footer was dropped:\n\(contents)")
    }

    func testCloseIsIdempotent() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let logger = try XCTUnwrap(SessionLogger(fileURL: url, title: "web-01", subtitle: ""))
        logger.append(ArraySlice(Array("line\n".utf8)))
        logger.close()
        logger.close()
        logger.close()

        let deadline = Date().addingTimeInterval(2)
        var contents = ""
        while Date() < deadline {
            contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if contents.contains("session ended") { break }
            usleep(20_000)
        }

        let footers = contents.components(separatedBy: "session ended").count - 1
        XCTAssertEqual(footers, 1, "footer written \(footers) times:\n\(contents)")
    }
}
