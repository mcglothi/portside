import Foundation
import XCTest
import SwiftTerm
@testable import Portside

/// The guard exists to stop a `fatalError` inside SwiftTerm, so the tests that
/// matter most run real payloads through a real `Terminal`. Without the guard
/// those cases abort the whole test process rather than failing — which is
/// exactly why the crash repro in `InlineImageProtocolTests` is opt-in.
final class SixelStreamGuardTests: XCTestCase {

    private let white = "#0;2;100;100;100#0"

    private func guarded(_ text: String, chunkSize: Int? = nil) -> [UInt8] {
        var sut = SixelStreamGuard()
        let bytes = [UInt8](text.utf8)
        guard let chunkSize else {
            return Array(sut.filter(bytes[...]))
        }
        var out: [UInt8] = []
        var index = 0
        while index < bytes.count {
            let end = min(index + chunkSize, bytes.count)
            out.append(contentsOf: sut.filter(bytes[index..<end]))
            index = end
        }
        return out
    }

    private func string(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Rewriting

    func testAppendsMissingTerminatorToFinalBand() {
        let out = guarded("\u{1b}Pq\(white)~~~-~~~~~~\u{1b}\\")
        XCTAssertEqual(string(out), "\u{1b}Pq\(white)~~~-~~~~~~-\u{1b}\\")
    }

    func testAppendsMissingTerminatorToSingleBandImage() {
        let out = guarded("\u{1b}Pq\(white)~~\u{1b}\\")
        XCTAssertEqual(string(out), "\u{1b}Pq\(white)~~-\u{1b}\\")
    }

    func testLeavesAlreadyTerminatedPayloadAlone() {
        let payload = "\u{1b}Pq\(white)~~~~~~-\u{1b}\\"
        XCTAssertEqual(string(guarded(payload)), payload)
    }

    func testTreatsCarriageReturnAsATerminator() {
        let payload = "\u{1b}Pq\(white)~~~~~~$\u{1b}\\"
        XCTAssertEqual(string(guarded(payload)), payload)
    }

    /// Colour selection, repeat counts and raster attributes are all below the
    /// pixel range, so none of them should look like an unmeasured band.
    func testColourSelectionAloneIsNotAband() {
        let payload = "\u{1b}Pq\"1;1;6;6\(white)~~~~~~-#1;2;0;100;0\u{1b}\\"
        XCTAssertEqual(string(guarded(payload)), payload)
    }

    func testRepeatIntroducerCountsAsPixels() {
        let out = guarded("\u{1b}Pq\(white)!6~\u{1b}\\")
        XCTAssertEqual(string(out), "\u{1b}Pq\(white)!6~-\u{1b}\\")
    }

    // MARK: - Leaving everything else alone

    func testOrdinaryOutputPassesThroughUnchanged() {
        let payload = "hello\r\n\u{1b}[31mred\u{1b}[0m\r\n"
        XCTAssertEqual(string(guarded(payload)), payload)
    }

    /// DECRQSS is `ESC P $ q`. It ends in `q` like sixel does and must not be
    /// mistaken for it — the intermediate is the only thing telling them apart.
    func testDECRQSSIsNotTreatedAsSixel() {
        let payload = "\u{1b}P$qm\u{1b}\\"
        XCTAssertEqual(string(guarded(payload)), payload)
    }

    func testOtherDCSPayloadsAreUntouched() {
        let payload = "\u{1b}P1$r0;1m\u{1b}\\"
        XCTAssertEqual(string(guarded(payload)), payload)
    }

    func testOSC133MarkersStillPassThrough() {
        let payload = "\u{1b}]133;D;0\u{07}\u{1b}]133;A\u{07}"
        XCTAssertEqual(string(guarded(payload)), payload)
    }

    // MARK: - Cancellation

    /// CAN (0x18) and SUB (0x1A) cancel any sequence in progress from *every*
    /// parser state — SwiftTerm has that as a global "anywhere" rule:
    ///
    ///     table.add(codes: [0x18, 0x1a, 0x99, 0x9a], state: state,
    ///               action: .execute, next: .ground)
    ///
    /// The guard has to leave with it. Staying in the DCS while the terminal has
    /// returned to ground means a later ordinary `q` and pixel-range text look
    /// like a Sixel payload here and like plain text there, and the guard writes
    /// a `-` into the middle of someone's output.
    ///
    /// Found by Codex CLI in the 0.17 pre-release review.
    func testCancelBeforeFinalByteIsNotTreatedAsSixel() {
        // ESC P CAN q ~ ~ ESC \ — cancelled before the DCS final byte, so the
        // `q~~` is ordinary text as far as the terminal is concerned.
        let payload = "\u{1b}P\u{18}q~~\u{1b}\\"
        XCTAssertEqual(string(guarded(payload)), payload, "nothing may be inserted after a cancel")
    }

    func testSubCancelBeforeFinalByteIsNotTreatedAsSixel() {
        let payload = "\u{1b}P\u{1a}q~~\u{1b}\\"
        XCTAssertEqual(string(guarded(payload)), payload)
    }

    /// Cancelling *inside* a real Sixel body abandons it too: the band never
    /// terminates, but the terminal is no longer decoding it, so there is
    /// nothing to repair.
    func testCancelInsideSixelBodyStopsTheRepair() {
        let payload = "\u{1b}Pq\(white)~~~\u{18} plain text \u{1b}\\"
        XCTAssertEqual(string(guarded(payload)), payload)
    }

    func testSubCancelInsideSixelBodyStopsTheRepair() {
        let payload = "\u{1b}Pq\(white)~~~\u{1a} plain text \u{1b}\\"
        XCTAssertEqual(string(guarded(payload)), payload)
    }

    /// ST before a DCS handler has been selected is a terminator too.
    func testStringTerminatorInPrologueEndsTheSequence() {
        let payload = "\u{1b}P\u{9c}q~~\u{1b}\\"
        XCTAssertEqual(string(guarded(payload)), payload)
    }

    /// A cancel must not poison the next, legitimate image.
    func testSixelAfterACancelStillGetsRepaired() {
        let cancelled = "\u{1b}P\u{18}q~~\u{1b}\\"
        let real = "\u{1b}Pq\(white)~~\u{1b}\\"
        let out = string(guarded(cancelled + real))
        XCTAssertEqual(out, cancelled + "\u{1b}Pq\(white)~~-\u{1b}\\")
    }

    /// Every cancellation vector, split at every boundary — the same treatment
    /// the positive cases get, because the cancel and the bytes that follow it
    /// can land in different chunks.
    func testCancellationSurvivesEveryChunkBoundary() {
        let payloads = [
            "\u{1b}P\u{18}q~~\u{1b}\\",
            "\u{1b}P\u{1a}q~~\u{1b}\\",
            "\u{1b}Pq\(white)~~~\u{18} plain \u{1b}\\",
            "\u{1b}P\u{9c}q~~\u{1b}\\",
        ]
        for payload in payloads {
            for chunkSize in 1...payload.utf8.count {
                XCTAssertEqual(
                    string(guarded(payload, chunkSize: chunkSize)),
                    payload,
                    "\(payload.debugDescription) split into \(chunkSize)-byte chunks"
                )
            }
        }
    }

    // MARK: - Chunking

    /// Output arrives in whatever sizes the transport hands over, so the
    /// terminator decision has to survive a split anywhere — including between
    /// the `ESC` and the `\` that together end the payload.
    func testRewritingSurvivesEveryChunkBoundary() {
        let input = "\u{1b}Pq\(white)~~~-~~~~~~\u{1b}\\"
        let expected = "\u{1b}Pq\(white)~~~-~~~~~~-\u{1b}\\"
        for chunkSize in 1...input.utf8.count {
            XCTAssertEqual(
                string(guarded(input, chunkSize: chunkSize)),
                expected,
                "split into \(chunkSize)-byte chunks"
            )
        }
    }

    func testPassthroughSurvivesEveryChunkBoundary() {
        let input = "\u{1b}Pq\(white)~~~~~~-\u{1b}\\ok\r\n"
        for chunkSize in 1...input.utf8.count {
            XCTAssertEqual(
                string(guarded(input, chunkSize: chunkSize)),
                input,
                "split into \(chunkSize)-byte chunks"
            )
        }
    }

    // MARK: - Against a real terminal

    /// The claim the guard rests on: appending the terminator yields exactly
    /// the image the upstream fix produces, because `-` folds the last band
    /// into the width without plotting anything that could change the height.
    func testGuardedPayloadsDecodeToUpstreamDimensions() {
        // (payload, expected width, expected height)
        let cases: [(String, Int, Int)] = [
            ("\u{1b}Pq\(white)~~~-~~~~~~\u{1b}\\", 6, 12),   // last band widest
            ("\u{1b}Pq\(white)~~\u{1b}\\", 2, 6),            // single band
            ("\u{1b}Pq\(white)!6~\u{1b}\\", 6, 6),           // run-length encoded
            ("\u{1b}Pq\(white)~~~~~~-~~~\u{1b}\\", 6, 12),   // last band narrower
        ]

        for (payload, width, height) in cases {
            let delegate = ImageRecordingDelegate()
            let terminal = Terminal(delegate: delegate)
            var sut = SixelStreamGuard()
            let repaired = sut.filter([UInt8](payload.utf8)[...])

            terminal.feed(byteArray: Array(repaired))

            XCTAssertEqual(delegate.bitmaps.first?.width, width, "width for \(payload.debugDescription)")
            XCTAssertEqual(delegate.bitmaps.first?.height, height, "height for \(payload.debugDescription)")
        }
    }

    /// An already-valid image must come out the far side identical, not merely
    /// uncrashed.
    func testGuardDoesNotAlterAValidImage() {
        let payload = "\u{1b}Pq\(white)~~~~~~-~~~~~~-\u{1b}\\"

        let direct = ImageRecordingDelegate()
        Terminal(delegate: direct).feed(text: payload)

        let viaGuard = ImageRecordingDelegate()
        var sut = SixelStreamGuard()
        Terminal(delegate: viaGuard).feed(byteArray: Array(sut.filter([UInt8](payload.utf8)[...])))

        XCTAssertEqual(direct.bitmaps.first?.width, viaGuard.bitmaps.first?.width)
        XCTAssertEqual(direct.bitmaps.first?.height, viaGuard.bitmaps.first?.height)
        XCTAssertEqual(direct.bitmaps.first?.bytes, viaGuard.bitmaps.first?.bytes)
    }

    final class ImageRecordingDelegate: TerminalDelegate {
        var bitmaps: [(width: Int, height: Int, bytes: Int)] = []

        func send(source: Terminal, data: ArraySlice<UInt8>) {}
        func mouseModeChanged(source: Terminal) {}
        func hostCurrentDirectoryUpdated(source: Terminal) {}
        func colorChanged(source: Terminal, idx: Int?) {}

        func createImageFromBitmap(source: Terminal, bytes: inout [UInt8], width: Int, height: Int) {
            bitmaps.append((width: width, height: height, bytes: bytes.count))
        }
    }
}
