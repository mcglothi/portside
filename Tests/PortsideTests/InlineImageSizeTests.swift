import AppKit
import XCTest
@testable import Portside

/// iTerm2 inline images are shown at their own size, so the guard checks the
/// size in the image's header as it arrives: PNG and JPEG up to 4096
/// pixels a side are shown, anything else isn't.
final class InlineImageSizeTests: XCTestCase {
    private func image(_ type: NSBitmapImageRep.FileType, width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: type, properties: [:])!
    }

    private func verdict(_ data: Data) -> ImageHeaderSniffer.Verdict {
        var sniffer = ImageHeaderSniffer()
        for byte in data where sniffer.feed(byte) != .undecided { break }
        return sniffer.verdict
    }

    /// How many images reached the terminal, through the guard as in the app.
    private func shown(_ data: Data, chunk: Int = .max) -> Int {
        let bytes = Array("\u{1b}]1337;File=inline=1:\(data.base64EncodedString())\u{07}".utf8)
        var filter = TerminalImageGuard()
        let h = TerminalHarness()
        var i = 0
        while i < bytes.count {
            let end = min(i + max(chunk, 1), bytes.count)
            h.feed(Array(filter.filtered(bytes[i..<end])))
            i = end
        }
        return h.images
    }

    func testOrdinaryImagesAreAllowed() {
        XCTAssertEqual(verdict(image(.png, width: 64, height: 48)), .allow)
        XCTAssertEqual(verdict(image(.jpeg, width: 64, height: 48)), .allow)
        XCTAssertEqual(verdict(image(.png, width: 4096, height: 1)), .allow, "the limit itself is fine")
    }

    func testOverTheLimitOrAnotherFormatIsRefused() {
        XCTAssertEqual(verdict(image(.png, width: 4097, height: 1)), .refuse)
        XCTAssertEqual(verdict(image(.jpeg, width: 1, height: 4097)), .refuse)
        XCTAssertEqual(verdict(image(.tiff, width: 8, height: 8)), .refuse)
        XCTAssertEqual(verdict(image(.bmp, width: 8, height: 8)), .refuse)
        XCTAssertEqual(verdict(image(.gif, width: 8, height: 8)), .refuse,
                       "a GIF's frames carry their own sizes past the header")
    }

    func testTheGuardShowsSmallImagesAndNotOthers() {
        for chunk in [1, 7, .max] {
            XCTAssertEqual(shown(image(.png, width: 32, height: 32), chunk: chunk), 1, "chunks of \(chunk)")
            XCTAssertEqual(shown(image(.jpeg, width: 32, height: 32), chunk: chunk), 1, "chunks of \(chunk)")
            XCTAssertEqual(shown(image(.png, width: 4097, height: 1), chunk: chunk), 0, "chunks of \(chunk)")
            XCTAssertEqual(shown(image(.tiff, width: 8, height: 8), chunk: chunk), 0, "chunks of \(chunk)")
        }
    }

    /// Other OSC 1337 commands and ordinary titles pass untouched.
    func testOtherSequencesAreUntouched() {
        for text in ["\u{1b}]1337;SetUserVar=x=YWJj\u{07}", "\u{1b}]0;File=a:b\u{07}", "\u{1b}]1337;CurrentDir=/tmp\u{07}"] {
            var filter = TerminalImageGuard()
            let bytes = Array(text.utf8)
            XCTAssertEqual(Array(filter.filtered(bytes[...])), bytes, text.debugDescription)
        }
    }
}
