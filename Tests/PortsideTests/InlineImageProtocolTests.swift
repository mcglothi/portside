import XCTest
import SwiftTerm

/// `docs/COMPATIBILITY.md` recorded Sixel, iTerm2 (OSC 1337) and Kitty graphics
/// as unsupported. That was measured against SwiftTerm 0.6.1-dev; the pinned
/// version is now 1.15.0, which parses all three and hands the decoded image to
/// the terminal delegate. These tests pin that down so the matrix stops being a
/// claim carried forward on faith -- if a future SwiftTerm bump drops a
/// protocol, the matrix is wrong again and this fails.
final class InlineImageProtocolTests: XCTestCase {

    /// Records the image callbacks a real front end (`AppleTerminalView`) would
    /// receive. Everything else is the smallest delegate `Terminal` will accept.
    final class ImageRecordingDelegate: TerminalDelegate {
        var bitmaps: [(width: Int, height: Int, bytes: Int)] = []
        var blobs: [Data] = []

        func send(source: Terminal, data: ArraySlice<UInt8>) {}
        func mouseModeChanged(source: Terminal) {}
        func hostCurrentDirectoryUpdated(source: Terminal) {}
        func colorChanged(source: Terminal, idx: Int?) {}

        func createImageFromBitmap(source: Terminal, bytes: inout [UInt8], width: Int, height: Int) {
            bitmaps.append((width: width, height: height, bytes: bytes.count))
        }

        func createImage(source: Terminal, data: Data, width: ImageSizeRequest, height: ImageSizeRequest, preserveAspectRatio: Bool) {
            blobs.append(data)
        }
    }

    private func makeTerminal() -> (Terminal, ImageRecordingDelegate) {
        let delegate = ImageRecordingDelegate()
        return (Terminal(delegate: delegate), delegate)
    }

    /// A 1x1 transparent PNG, the smallest payload the iTerm2 and Kitty
    /// protocols can carry that is still a real decodable image.
    private let onePixelPNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

    /// DCS q, one colour registered as white, six `~` sixels (every one of the
    /// six bits set, so a 6x6 block), band terminated with `-`.
    ///
    /// The terminator is load-bearing: without it this vector crashes the
    /// process on the pinned SwiftTerm. See `testSixelUnterminatedFinalBand`.
    func testSixelIsDecodedToABitmap() {
        let (terminal, delegate) = makeTerminal()

        terminal.feed(text: "\u{1b}Pq#0;2;100;100;100#0~~~~~~-\u{1b}\\")

        XCTAssertEqual(delegate.bitmaps.count, 1, "Sixel data should reach the delegate as a decoded bitmap")
        let bitmap = delegate.bitmaps.first
        XCTAssertEqual(bitmap?.width, 6)
        XCTAssertEqual(bitmap?.height, 6)
        // RGBA, 8 bits per channel.
        XCTAssertEqual(bitmap?.bytes, 6 * 6 * 4)
    }

    /// Multi-band sixel, each band terminated. Exercises the normal shape of a
    /// real image rather than the single-band minimum.
    func testSixelMultiBandImage() {
        let (terminal, delegate) = makeTerminal()

        terminal.feed(text: "\u{1b}Pq#0;2;100;100;100#0~~~~~~-~~~~~~-~~~~~~-\u{1b}\\")

        XCTAssertEqual(delegate.bitmaps.first?.width, 6)
        XCTAssertEqual(delegate.bitmaps.first?.height, 18)
    }

    /// Upstream defect, characterised 2026-07-27 against SwiftTerm 1.15.0.
    ///
    /// `SixelDcsHandler.sizePixels()` only widens `maxX` when it sees `$` or
    /// `-`. A final band terminated by neither is missing from the measurement,
    /// so `readPixels()` writes at `((y + k) * maxX + x) * 4` with an `x` past
    /// `maxX` and runs off the end of the `pixels` array. That is a
    /// `fatalError`, not a throw — it takes the whole app down, from ordinary
    /// remote output.
    ///
    /// Triggers whenever the *last* band is wider than every terminated band
    /// before it, which includes every single-band image of width >= 2.
    ///
    /// The fix is one line in `unhook()`, before the buffer is allocated:
    ///     maxX = max (maxX, x)
    /// Verified locally against the vectors below: all decode to the right
    /// dimensions with it, and cases 1 and 3 crash without it.
    ///
    /// Disabled by default: it would abort the whole test process, not fail a
    /// single case. Run deliberately with PORTSIDE_SIXEL_CRASH_REPRO=1 to
    /// confirm the defect still exists after a SwiftTerm bump.
    func testSixelUnterminatedFinalBand() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PORTSIDE_SIXEL_CRASH_REPRO"] == "1",
            "Crashes the test process on unpatched SwiftTerm; opt in explicitly."
        )

        let white = "#0;2;100;100;100#0"
        let vectors = [
            "\u{1b}Pq\(white)~~~~~~-~~~\u{1b}\\",       // last band narrower  - safe
            "\u{1b}Pq\(white)~~~-~~~~~~\u{1b}\\",       // last band wider     - CRASHES
            "\u{1b}Pq\(white)~~~~~~-~~~~~~\u{1b}\\",    // last band equal     - safe
            "\u{1b}Pq\(white)~~\u{1b}\\",               // single band         - CRASHES
        ]

        for vector in vectors {
            let (terminal, delegate) = makeTerminal()
            terminal.feed(text: vector)
            XCTAssertFalse(delegate.bitmaps.isEmpty)
        }
    }

    func testITerm2InlineImageReachesTheDelegate() {
        let (terminal, delegate) = makeTerminal()

        terminal.feed(text: "\u{1b}]1337;File=inline=1;width=2;height=2:\(onePixelPNGBase64)\u{07}")

        XCTAssertEqual(delegate.blobs.count, 1, "OSC 1337 should reach the delegate as an image blob")
        // Decoded back to the original bytes, not the base64 text.
        XCTAssertEqual(delegate.blobs.first?.prefix(8), Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
    }

    func testKittyGraphicsReachesTheDelegate() {
        let (terminal, delegate) = makeTerminal()

        // a=T: transmit and display immediately. f=100: the payload is a PNG.
        terminal.feed(text: "\u{1b}_Ga=T,f=100;\(onePixelPNGBase64)\u{1b}\\")

        XCTAssertFalse(
            delegate.blobs.isEmpty && delegate.bitmaps.isEmpty,
            "Kitty graphics should reach the delegate by one of the two image callbacks"
        )
    }
}
