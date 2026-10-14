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
    private func send(_ commands: [(String, String)], chunk: Int = .max, guarded: Bool = true) -> String {
        let bytes = Array(commands.map { "\u{1b}_G\($0.0);\($0.1)\u{1b}\\" }.joined().utf8)
        return sendBytes(bytes, chunk: chunk, guarded: guarded)
    }

    /// For an image within the limit the guard must not change SwiftTerm's
    /// answer, whatever SwiftTerm makes of an odd spelling: these compare
    /// against the unguarded reply rather than pinning one SwiftTerm's parser.
    private func sameAsUnguarded(_ commands: [(String, String)], chunk: Int = .max) -> Bool {
        accepted(send(commands, chunk: chunk)) == accepted(send(commands, guarded: false))
    }

    private func sendBytes(_ bytes: [UInt8], chunk: Int = .max, guarded: Bool = true,
                           file: StaticString = #filePath, line: UInt = #line) -> String {
        Self.watched("\(name), chunks of \(chunk)", file: file, line: line) {
            var filter = TerminalImageGuard()
            let h = TerminalHarness()
            var i = 0
            while i < bytes.count {
                let end = i + min(max(chunk, 1), bytes.count - i)
                h.feed(guarded ? Array(filter.filtered(bytes[i..<end])) : Array(bytes[i..<end]))
                i = end
            }
            return String(decoding: h.replies, as: UTF8.self)
        } ?? ""
    }

    /// Runs `work` with a deadline. An image the guard should have refused
    /// can leave SwiftTerm decoding for minutes; on CI that stalled the whole
    /// run with nothing in the log. Past the deadline the test fails, named,
    /// and the suite moves on (the stuck thread is left behind).
    static func watched<T>(_ what: String, seconds: Int = 20,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ work: @escaping () -> T) -> T? {
        let box = WatchBox<T>()
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            box.value = work()
            done.signal()
        }
        guard done.wait(timeout: .now() + .seconds(seconds)) == .success else {
            XCTFail("SwiftTerm didn't return within \(seconds)s: \(what)", file: file, line: line)
            return nil
        }
        return box.value
    }

    override func setUp() {
        super.setUp()
        // stderr isn't buffered: if anything here stalls, the CI log says
        // which test it was.
        FileHandle.standardError.write(Data("KittyImageSizeTests: \(name)\n".utf8))
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
    /// chunk. Once premature padding refuses the header, the guard removes
    /// the rest of the transfer even if the decoder would continue past it.
    func testPaddingInAnEarlyChunkDoesntLetALargerImageThrough() {
        let big = image(.png, width: 4097, height: 1)
        XCTAssertEqual(big.prefix(2).base64EncodedString(), "iVA=")
        let rest = big.dropFirst(2).base64EncodedString()
        XCTAssertFalse(accepted(send([("a=t,f=100,i=7,m=1", "iVA="), ("m=0", rest)])))
        let small = image(.png, width: 32, height: 32)
        XCTAssertFalse(accepted(send([("a=t,f=100,i=7,m=1", "iVA="), ("m=0", small.dropFirst(2).base64EncodedString())])),
                       "not even a small one: the refused suffix is removed")
    }

    func testACompressedPNGIsRefused() {
        XCTAssertFalse(accepted(send([("a=t,f=100,o=z,i=7", image(.png, width: 8, height: 8).base64EncodedString())])))
    }

    /// Refused in the key, before SwiftTerm's decompression runs: on macOS 15
    /// that step stalled on a refused payload. Whatever order the keys come
    /// in, and for raw pixels too.
    func testCompressionIsTurnedAwayBeforeDecompressing() {
        let png = image(.png, width: 8, height: 8).base64EncodedString()
        for control in ["a=t,o=z,f=100,i=7", "a=t,f=100,o=z,i=7", "a=t,o=z,o=z,f=100,i=7"] {
            let reply = send([(control, png)])
            XCTAssertFalse(accepted(reply), control)
            XCTAssertTrue(reply.contains("i=7;"), "\(control): SwiftTerm answered (\(reply))")
        }
        // What SwiftTerm is handed: the compression key no longer says z.
        for control in ["o=z,f=100", "f=100,o=z", "f=32,o=z"] {
            var filter = TerminalImageGuard()
            let bytes = Array("\u{1b}_G\(control);AAAA\u{1b}\\".utf8)
            let handed = String(decoding: Array(filter.filtered(bytes[...])), as: UTF8.self)
            XCTAssertTrue(handed.contains("o=X") && !handed.contains("o=z"), "\(control): \(handed.debugDescription)")
        }
        let raw = Data(repeating: 0, count: 16).base64EncodedString()
        XCTAssertFalse(accepted(send([("a=t,f=32,s=2,v=2,o=z,i=7", raw)])), "compressed raw pixels too")
        XCTAssertTrue(accepted(send([("a=t,f=32,s=2,v=2,i=7", raw)])), "uncompressed still fine")
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


    func testNumericFormatsCannotBypassTheHeaderCheck() {
        let large = image(.png, width: 4097, height: 1).base64EncodedString()
        let small = image(.png, width: 32, height: 32).base64EncodedString()
        for format in ["+100", "0100", String(repeating: "0", count: 256) + "100"] {
            for chunk in [1, 5, .max] {
                XCTAssertFalse(accepted(send([("f=\(format),i=7", large)], chunk: chunk)), format)
                XCTAssertTrue(sameAsUnguarded([("f=\(format),i=7", small)], chunk: chunk), format)
            }
        }
    }

    func testLastASCIIFormatWinsIncludingEmptyAndInvalidValues() {
        let large = image(.png, width: 4097, height: 1).base64EncodedString()
        for keys in ["f=32,f=+100", "f=100,f=é", "f=100,f=32é", "f=100,fé=32"] {
            XCTAssertFalse(accepted(send([(keys + ",i=7", large)], chunk: 1)), keys)
        }
        let raw = Data(repeating: 0, count: 16).base64EncodedString()
        for value in ["32", "", "invalid", "100=", " 100", "+", "-100", "9223372036854775808"] {
            // -100 is a valid integer but an unsupported format; other invalid
            // values default to raw 32. All must replace the earlier f=100.
            XCTAssertTrue(sameAsUnguarded([("f=100,f=\(value),s=2,v=2,i=7", raw)]), value)
        }
        let small = image(.png, width: 32, height: 32).base64EncodedString()
        XCTAssertTrue(sameAsUnguarded([("f=100,o=z,o=,i=7", small)]))
        XCTAssertTrue(sameAsUnguarded([("f=100,o=é,i=7", small)], chunk: 1))
    }

    /// SwiftTerm 2 ignores an empty value and one past 11 bytes, keeping the
    /// earlier value, and drops a command whose value doesn't parse. Read the
    /// 1.x way — empty or unparseable means the default, raw 32 — these left
    /// the guard expecting raw pixels while SwiftTerm decoded a PNG.
    func testFormatsSwiftTermKeepsAreStillChecked() {
        let large = image(.png, width: 4097, height: 1).base64EncodedString()
        let small = image(.png, width: 32, height: 32).base64EncodedString()
        for keys in ["f=100,f=", "f=100,f=000000000032", "f=100,f=" + String(repeating: "0", count: 30) + "32",
                     "f=100,i=7,f=,s=1,v=1"] {
            for chunk in [1, 5, .max] {
                XCTAssertFalse(accepted(send([(keys + ",i=7", large)], chunk: chunk)), keys)
                XCTAssertTrue(sameAsUnguarded([(keys + ",i=7", small)], chunk: chunk), keys)
            }
        }
    }

    /// A command SwiftTerm can't parse is ignored whole: it neither starts nor
    /// ends a chunked transfer, so the guard's check must carry straight past it.
    func testAnUnparseableCommandLeavesTheTransferAlone() {
        let large = image(.png, width: 4097, height: 1).base64EncodedString()
        let small = image(.png, width: 32, height: 32).base64EncodedString()
        for junk in ["i=x", "m=-1", "z=99999999999", "f=1é"] {
            for payload in [small, large] {
                let commands = [("f=100,i=7,m=1", String(payload.prefix(8))),
                                ("f=32,s=1,v=1,m=0,\(junk)", "AAAA"),
                                ("m=0", String(payload.dropFirst(8)))]
                if payload == small {
                    XCTAssertTrue(sameAsUnguarded(commands, chunk: 1), junk)
                } else {
                    XCTAssertFalse(accepted(send(commands, chunk: 1)), junk)
                }
            }
        }
    }

    func testIncompleteStandaloneImageDoesNotPoisonNextImage() {
        let small = image(.png, width: 32, height: 32).base64EncodedString()
        for more in ["", ",m=0", ",m=1,m=0", ",m=1,m=", ",m=1,m=garbage", ",m=1,m=-1"] {
            for chunk in [1, 5, .max] {
                XCTAssertTrue(sameAsUnguarded([("f=100,i=8" + more, "iVBO"),
                                               ("f=100,i=7", small)], chunk: chunk), more)
            }
        }
    }

    func testNumericMoreAndRepeatedKeysPreservePendingHeader() {
        let large = image(.png, width: 4097, height: 1).base64EncodedString()
        let small = image(.png, width: 32, height: 32).base64EncodedString()
        for more in ["+1", "01", String(repeating: "0", count: 256) + "1", "0,m=1", "1,m=é", "1,m=0é"] {
            for payload in [small, large] {
                let commands = [("f=100,i=7,m=\(more)", String(payload.prefix(4))),
                                ("f=32,m=0", String(payload.dropFirst(4)))]
                if payload == small {
                    XCTAssertTrue(sameAsUnguarded(commands, chunk: 1), more)
                } else {
                    XCTAssertFalse(accepted(send(commands, chunk: 1)), more)
                }
            }
        }
    }

    func testFinalChunkClearsAnUndecidedHeader() {
        let small = image(.png, width: 32, height: 32).base64EncodedString()
        XCTAssertTrue(accepted(send([("f=100,i=8,m=1", "iVBO"), ("m=0", ""),
                                     ("f=100,i=7", small)])))
    }

    func testDeleteClearsPendingEvenWithoutSemicolon() {
        let small = image(.png, width: 32, height: 32).base64EncodedString()
        for action in ["d", "D"] {
            // Deletion ends the refused transfer before this payload. Preserve
            // the new command's bytes, even when it starts an m=1 transaction
            // whose action is deletion (its payload is not an image).
            var filter = TerminalImageGuard()
            let refused = Array("\u{1b}_Gf=100,m=1;=\u{1b}\\".utf8)
            _ = filter.filtered(refused[...])
            let deletion = Array("\u{1b}_Ga=\(action),m=1;unchanged\u{1b}\\".utf8)
            XCTAssertEqual(Array(filter.filtered(deletion[...])), deletion)
            for suffix in ["", ";"] {
                let stream = "\u{1b}_Gf=100,i=8,m=1;iVBO\u{1b}\\"
                    + "\u{1b}_Ga=\(action)\(suffix)\u{1b}\\"
                    + "\u{1b}_Gf=100,i=7;\(small)\u{1b}\\"
                XCTAssertTrue(accepted(sendBytes(Array(stream.utf8), chunk: 1)))
            }
        }
    }

    func testNonDirectMediumCannotLeavePendingState() {
        let small = image(.png, width: 32, height: 32).base64EncodedString()
        XCTAssertTrue(sameAsUnguarded([("f=100,t=f,m=1,i=8", "iVBO"), ("f=100,i=7", small)]))
        XCTAssertTrue(sameAsUnguarded([("f=100,m=1,i=8", "iVBO"), ("t=f,m=1", ""),
                                       ("f=100,i=7", small)]))
        XCTAssertTrue(sameAsUnguarded([("f=100,t=f,t=,m=1,i=7", String(small.prefix(4))),
                                       ("m=0", String(small.dropFirst(4)))]))
    }

    func testAbortedCommandsNeitherCreateNorConsumePendingState() {
        let small = image(.png, width: 32, height: 32).base64EncodedString()
        let large = image(.png, width: 4097, height: 1).base64EncodedString()
        for abort: UInt8 in [0x18, 0x1A] {
            let aborted = Array("\u{1b}_Gf=100,m=1;iVBO".utf8) + [abort] + Array("\u{1b}\\".utf8)
            let fresh = Array("\u{1b}_Gf=100,i=7;\(small)\u{1b}\\".utf8)
            XCTAssertTrue(accepted(sendBytes(aborted + fresh, chunk: 1)), "abort \(abort)")
            let first = Array("\u{1b}_Gf=100,i=7,m=1;\(small.prefix(4))\u{1b}\\".utf8)
            let last = Array("\u{1b}_Gm=0;\(small.dropFirst(4))\u{1b}\\".utf8)
            XCTAssertTrue(accepted(sendBytes(first + aborted + last, chunk: 1)), "abort \(abort)")
        }
        // C1 bytes no longer abort an APC in SwiftTerm 2 — mid-run they're
        // content — and the guard makes them content at any split. Whatever
        // SwiftTerm makes of the result, the guard agrees with it, and an
        // oversized image is still refused.
        for c1: UInt8 in [0x9B, 0x9D, 0x90, 0x9F, 0x98, 0x9E, 0x9C] {
            let interrupted = Array("\u{1b}_Gf=100,m=1;iVBO".utf8) + [c1] + Array("\u{1b}\\".utf8)
            for payload in [small, large] {
                let first = Array("\u{1b}_Gf=100,i=7,m=1;\(payload.prefix(4))\u{1b}\\".utf8)
                let last = Array("\u{1b}_Gm=0;\(payload.dropFirst(4))\u{1b}\\".utf8)
                for bytes in [interrupted + Array("\u{1b}_Gf=100,i=7;\(payload)\u{1b}\\".utf8),
                              first + interrupted + last, first + [c1] + last] {
                    let guarded = accepted(sendBytes(bytes, chunk: 1))
                    if payload == small {
                        XCTAssertEqual(guarded, accepted(sendBytes(bytes, guarded: false)), "C1 \(c1)")
                    } else {
                        XCTAssertFalse(guarded, "C1 \(c1)")
                    }
                }
            }
        }
        let first = "\u{1b}_Gf=100,i=7,m=1;\(small.prefix(4))\u{1b}\\"
        let abortedDelete = "\u{1b}_Ga=d;\u{18}"
        let last = "\u{1b}_Gm=0;\(small.dropFirst(4))\u{1b}\\"
        XCTAssertTrue(accepted(sendBytes(Array((first + abortedDelete + last).utf8))))
    }

    func testDispatchTerminatorsAndEmptyFirstChunk() {
        let small = image(.png, width: 32, height: 32).base64EncodedString()
        let large = image(.png, width: 4097, height: 1).base64EncodedString()
        for end: [UInt8] in [[0x1B, 0x5C], [0x07], [0x9C]] {
            for trailingKey in ["", ","] {
                let first = Array("\u{1b}_Gf=100,i=7,m=1\(trailingKey)".utf8) + end
                let last = Array("\u{1b}_Gm=0;\(small)".utf8) + end
                // SwiftTerm 2 doesn't end an APC at a raw C1 ST: it's content.
                XCTAssertEqual(accepted(sendBytes(first + last, chunk: 1)), end != [0x9C], "\(end)\(trailingKey)")
                XCTAssertEqual(accepted(sendBytes(first + last, chunk: 1)),
                               accepted(sendBytes(first + last, guarded: false)), "\(end)\(trailingKey)")
                let oversized = Array("\u{1b}_Gm=0;\(large)".utf8) + end
                XCTAssertFalse(accepted(sendBytes(first + oversized, chunk: 1)))
            }
        }
    }

    func testContinuationKeysCannotStartAnotherImageCheck() {
        let small = image(.png, width: 32, height: 32).base64EncodedString()
        for split in [4, 64] { // before and after the header decision
            XCTAssertTrue(accepted(send([("f=100,i=7,m=1", String(small.prefix(split))),
                                         ("f=100,o=z,m=0", String(small.dropFirst(split)))])))
        }
        let raw = Data(repeating: 0, count: 16).base64EncodedString()
        XCTAssertTrue(accepted(send([("f=32,s=2,v=2,i=7,m=1", String(raw.prefix(4))),
                                     ("f=100,o=z,m=0", String(raw.dropFirst(4)))])))
    }

    /// Exercise a decoder *more* permissive than Foundation: discard every
    /// internal padding byte, restore legal trailing padding, then ask the real
    /// SwiftTerm decoder whether an image can be recovered. This must still fail.
    func testRefusalSurvivesADecoderThatIgnoresAllInternalPadding() {
        for type: NSBitmapImageRep.FileType in [.png, .jpeg] {
            for width in [32, 4097] {
                let payload = image(type, width: width, height: 1).base64EncodedString()
                for prefix in ["", "="] {
                    if prefix.isEmpty && width == 32 { continue }
                    var filter = TerminalImageGuard()
                    var guardedPayload = ""
                    let parts = [prefix + String(payload.prefix(4)), String(payload.dropFirst(4))]
                    for (index, part) in parts.enumerated() {
                        let keys = index == 0 ? "f=100,i=7,m=1" : "m=0"
                        let command = Array("\u{1b}_G\(keys);\(part)\u{1b}\\".utf8)
                        let output = Array(filter.filtered(command[...]))
                        let start = output.firstIndex(of: 59)! + 1
                        guardedPayload += String(decoding: output[start..<(output.count - 2)], as: UTF8.self)
                    }
                    var recovered = guardedPayload.filter { $0 != "=" }
                    recovered += String(repeating: "=", count: (4 - recovered.utf8.count % 4) % 4)
                    let reply = Self.watched("\(name), permissive decode") {
                        let h = TerminalHarness()
                        h.feed("\u{1b}_Gf=100,i=7;\(recovered)\u{1b}\\")
                        return String(decoding: h.replies, as: UTF8.self)
                    } ?? ""
                    XCTAssertFalse(accepted(reply))
                }
            }
        }
    }
}

/// Hands a result back from the watchdog's thread.
private final class WatchBox<T>: @unchecked Sendable {
    var value: T?
    init() {}
}
