import AppKit
import XCTest
@testable import Portside

/// Kitty images are bounded like iTerm2's: PNG and JPEG (`f=100`) up to 4096
/// pixels a side by their header, raw pixels (`f=24`/`f=32`) by `s` and `v`.
/// Checked by what SwiftTerm replies to a transmit (`a=t`): `OK`, or an error.
final class KittyImageSizeTests: XCTestCase {
    private func image(_ type: NSBitmapImageRep.FileType, width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: type, properties: [:])!
    }

    /// Sends `commands` (control, payload) through the guard, returns the
    /// replies. `chunk` is the read size.
    private func send(_ commands: [(String, String)], chunk: Int = .max) -> String {
        let bytes = Array(commands.map { "\u{1b}_G\($0.0);\($0.1)\u{1b}\\" }.joined().utf8)
        var filter = TerminalImageGuard()
        let h = TerminalHarness()
        var i = 0
        while i < bytes.count {
            let end = min(i + max(chunk, 1), bytes.count)
            h.feed(Array(filter.filtered(bytes[i..<end])))
            i = end
        }
        return String(decoding: h.replies, as: UTF8.self)
    }

    private func accepted(_ reply: String) -> Bool { reply.contains("i=7;OK") }

    func testPNGAndJPEGWithinTheLimitAreAccepted() {
        for chunk in [1, 5, .max] {
            XCTAssertTrue(accepted(send([("a=t,f=100,i=7", image(.png, width: 32, height: 32).base64EncodedString())], chunk: chunk)))
            XCTAssertTrue(accepted(send([("a=t,f=100,i=7", image(.jpeg, width: 32, height: 32).base64EncodedString())], chunk: chunk)))
        }
    }

    func testLargerOrOtherFormatsAreRefused() {
        for chunk in [1, 5, .max] {
            XCTAssertFalse(accepted(send([("a=t,f=100,i=7", image(.png, width: 4097, height: 1).base64EncodedString())], chunk: chunk)))
            XCTAssertFalse(accepted(send([("a=t,f=100,i=7", image(.tiff, width: 8, height: 8).base64EncodedString())], chunk: chunk)))
        }
    }

    /// Kitty sends big images in chunks (`m=1`), and the header can be in
    /// any of them — the first chunk may even be empty.
    func testAChunkedImageIsCheckedAcrossChunks() {
        func chunked(_ data: Data, emptyFirst: Bool) -> [(String, String)] {
            let b64 = Array(data.base64EncodedString())
            var parts = stride(from: 0, to: b64.count, by: 8).map { String(b64[$0..<min($0 + 8, b64.count)]) }
            if emptyFirst { parts.insert("", at: 0) }
            return parts.enumerated().map { i, part in
                let more = i < parts.count - 1 ? 1 : 0
                return (i == 0 ? "a=t,f=100,i=7,m=\(more)" : "m=\(more)", part)
            }
        }
        for emptyFirst in [false, true] {
            XCTAssertTrue(accepted(send(chunked(image(.png, width: 32, height: 32), emptyFirst: emptyFirst))))
            XCTAssertFalse(accepted(send(chunked(image(.png, width: 4097, height: 1), emptyFirst: emptyFirst))))
        }
    }

    /// SwiftTerm skips characters outside base64 in a Kitty payload, so the
    /// check has to as well, or one stray byte would end it early.
    func testStrayCharactersDontHideTheHeader() {
        var b64 = image(.png, width: 4097, height: 1).base64EncodedString()
        b64.insert("!", at: b64.index(b64.startIndex, offsetBy: 4))
        XCTAssertFalse(accepted(send([("a=t,f=100,i=7", b64)])))
    }

    /// A chunk that ends in padding before the header is complete (`iVA=` is
    /// a PNG's first two bytes), with the rest of a larger PNG in the next
    /// chunk. SwiftTerm joins the chunks and decodes once, and Foundation's
    /// lenient decode stops at the first padding, so all it gets is those two
    /// bytes: no image. Pinned so a SwiftTerm that decoded per chunk would
    /// show up here.
    func testPaddingInAnEarlyChunkDoesntLetALargerImageThrough() {
        let big = image(.png, width: 4097, height: 1)
        XCTAssertEqual(big.prefix(2).base64EncodedString(), "iVA=")
        let rest = big.dropFirst(2).base64EncodedString()
        XCTAssertFalse(accepted(send([("a=t,f=100,i=7,m=1", "iVA="), ("m=0", rest)])))
        let small = image(.png, width: 32, height: 32)
        XCTAssertFalse(accepted(send([("a=t,f=100,i=7,m=1", "iVA="), ("m=0", small.dropFirst(2).base64EncodedString())])),
                       "not even a small one: the decode stops at the padding")
    }

    func testACompressedPNGIsRefused() {
        XCTAssertFalse(accepted(send([("a=t,f=100,o=z,i=7", image(.png, width: 8, height: 8).base64EncodedString())])))
    }

    /// Raw pixels: the size is in the keys.
    func testRawPixelsAreBoundedBySAndV() {
        let small = Data(repeating: 0, count: 2 * 2 * 4).base64EncodedString()
        XCTAssertTrue(accepted(send([("a=t,f=32,s=2,v=2,i=7", small)])))
        let wide = Data(repeating: 0, count: 4097 * 4).base64EncodedString()
        XCTAssertFalse(accepted(send([("a=t,f=32,s=4097,v=1,i=7", wide)])))
        XCTAssertFalse(accepted(send([("a=t,f=32,s=+4097,v=1,i=7", wide)])), "Int() takes a leading +")
        XCTAssertFalse(accepted(send([("a=t,f=32,v=1,s=4,s=4097,i=7", wide)])), "the last of a repeated key wins")
        let tall = Data(repeating: 0, count: 4097 * 3).base64EncodedString()
        XCTAssertFalse(accepted(send([("a=t,f=24,s=1,v=4097,i=7", tall)])))
    }
}
