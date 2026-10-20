import AppKit
import XCTest
@testable import Portside

/// A remote program could make SwiftTerm open files and shared memory on the
/// Mac through Kitty graphics (`t=f`, `t=t`, `t=s`), and its replies said
/// whether a path existed and how big it was. A few bytes of sixel could crash
/// Portside or make it allocate gigabytes. `TerminalImageGuard` rewrites both
/// before SwiftTerm sees them; these tests feed the guarded bytes to a real
/// SwiftTerm parser and check what it did.
final class TerminalImageGuardTests: XCTestCase {
    private var scratch: [String] = []

    override func tearDown() {
        for path in scratch { try? FileManager.default.removeItem(atPath: path) }
        super.tearDown()
    }

    /// The bytes through a fresh filter, `chunk` at a time, into a fresh
    /// terminal. Returns what the terminal replied to the remote program.
    private func reply(to sequence: [UInt8], chunk: Int = .max) -> String {
        String(decoding: guarded(sequence, chunk: chunk).replies, as: UTF8.self)
    }

    /// A fresh terminal fed `sequence` through a fresh guard, `chunk` bytes
    /// at a time — the way a pty's reads arrive.
    private func guarded(_ sequence: [UInt8], chunk: Int = .max) -> TerminalHarness {
        var filter = TerminalImageGuard()
        let harness = TerminalHarness()
        var i = 0
        while i < sequence.count {
            let end = min(i + max(chunk, 1), sequence.count)
            harness.feed(Array(filter.filtered(sequence[i..<end])))
            i = end
        }
        return harness
    }

    private func apc(_ control: String, _ payload: String) -> [UInt8] {
        Array("\u{1b}_G\(control);\(Data(payload.utf8).base64EncodedString())\u{1b}\\".utf8)
    }

    /// The guard rewrites a file medium to one SwiftTerm doesn't know. 1.x
    /// answered that with ENOTSUP; 2.0 answers EINVAL. Either is a refusal
    /// that says nothing about the file.
    static func refused(_ reply: String) -> Bool {
        reply.contains("ENOTSUP") || reply.contains("EINVAL: unsupported medium")
    }

    private func scratchFile(named name: String, bytes: Int) -> String {
        let path = NSTemporaryDirectory() + name
        FileManager.default.createFile(atPath: path, contents: Data(repeating: 7, count: bytes))
        scratch.append(path)
        return path
    }

    // MARK: The leak

    func testWhetherAFileExistsIsNoLongerAnswered() {
        let existing = scratchFile(named: "portside-kitty-\(UUID().uuidString)", bytes: 16)
        let missing = existing + "-missing"
        let a = reply(to: apc("a=t,t=f,i=7", existing))
        let b = reply(to: apc("a=t,t=f,i=7", missing))
        XCTAssertEqual(a, b, "the reply must not depend on whether the path exists")
        XCTAssertTrue(Self.refused(a), a)
    }

    func testAFilesSizeIsNoLongerAnswered() {
        // 16 bytes is exactly a 2x2 RGBA image, which SwiftTerm accepted with OK.
        let path = scratchFile(named: "portside-kitty-\(UUID().uuidString)", bytes: 16)
        let r = reply(to: apc("a=t,t=f,f=32,s=2,v=2,i=7", path))
        XCTAssertFalse(r.contains(";OK"), r)
        XCTAssertTrue(Self.refused(r), r)
    }

    func testATemporaryFileIsNotDeleted() {
        let path = scratchFile(named: "tty-graphics-protocol-\(UUID().uuidString)", bytes: 4)
        _ = reply(to: apc("a=t,t=t,f=32,s=1,v=1,i=7", path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path),
                      "t=t deletes the file it reads; the filter must stop the read")
    }

    /// SwiftTerm unlinks the shared-memory object a `t=s` request names,
    /// whether or not it holds an image. "Unsupported" is decided before
    /// `shm_open` is called, so the reply is the proof that nothing was
    /// opened. (Creating a real object to watch isn't reliable from Swift:
    /// `shm_open` is variadic, and on arm64 its mode can't be passed.)
    func testSharedMemoryIsNotOpened() {
        let r = reply(to: apc("a=t,t=s,f=32,s=1,v=1,i=7", "/portside-kitty-\(getpid())"))
        XCTAssertTrue(Self.refused(r), r)
    }

    // MARK: What must keep working

    func testInlineImagesStillWork() {
        let pixel = Data([255, 0, 0, 255]).base64EncodedString()
        let r = reply(to: Array("\u{1b}_Ga=t,t=d,f=32,s=1,v=1,i=9;\(pixel)\u{1b}\\".utf8))
        XCTAssertTrue(r.contains("i=9;OK"), r)
        let implicit = reply(to: Array("\u{1b}_Ga=t,f=32,s=1,v=1,i=9;\(pixel)\u{1b}\\".utf8))
        XCTAssertTrue(implicit.contains("i=9;OK"), implicit)
    }

    func testOrdinaryOutputIsLeftAlone() {
        var filter = TerminalImageGuard()
        let text = Array("a,t=f and Gt=s 日本語 😀\r\n\u{1b}[31mred\u{1b}[0m \u{1b}]0;t=f\u{07}".utf8)
        XCTAssertEqual(Array(filter.filtered(text[...])), text)
    }

    // MARK: Ways around it

    /// Each of these is read by SwiftTerm as a file transmission. All of them
    /// must come back unsupported, whatever size the pty's reads happen to be.
    func testEveryWayOfSpellingItIsCaughtAtEveryChunkSize() {
        let path = scratchFile(named: "portside-kitty-\(UUID().uuidString)", bytes: 16)
        let b64 = Data(path.utf8).base64EncodedString()
        let spellings: [(String, [UInt8])] = [
            ("plain", Array("\u{1b}_Ga=t,t=f,f=32,s=2,v=2,i=7;\(b64)\u{1b}\\".utf8)),
            ("first key", Array("\u{1b}_Gt=f,a=t,f=32,s=2,v=2,i=7;\(b64)\u{1b}\\".utf8)),
            ("duplicate key, last wins", Array("\u{1b}_Ga=t,t=d,t=f,f=32,s=2,v=2,i=7;\(b64)\u{1b}\\".utf8)),
            ("C0 controls inside", Array("\u{1b}_Ga=t,t\u{01}=\u{0e}f,f=32,s=2,v=2,i=7;\(b64)\u{1b}\\".utf8)),
            ("controls before G", Array("\u{1b}_\u{0f}G\u{01}t=f,a=t,f=32,s=2,v=2,i=7;\(b64)\u{1b}\\".utf8)),
            ("control between ESC and _", Array("\u{1b}\u{01}_Ga=t,t=f,f=32,s=2,v=2,i=7;\(b64)\u{1b}\\".utf8)),
            ("C1 APC after CSI", Array("\u{1b}[1".utf8) + [0x9F] + Array("Ga=t,t=f,f=32,s=2,v=2,i=7;\(b64)\u{1b}\\".utf8)),
            ("BEL terminated", Array("\u{1b}_Ga=t,t=f,f=32,s=2,v=2,i=7;\(b64)\u{07}".utf8)),
            ("multi-character value", Array("\u{1b}_Ga=t,t=fff,f=32,s=2,v=2,i=7;\(b64)\u{1b}\\".utf8)),
        ]
        for (label, bytes) in spellings {
            for chunk in [1, 2, 3, 7, .max] {
                let r = reply(to: bytes, chunk: chunk)
                XCTAssertFalse(r.contains(";OK"), "\(label), chunks of \(chunk): \(r)")
                // SwiftTerm 2 drops a command with a multi-character medium
                // without answering at all, which leaks nothing either.
                let silent = label == "multi-character value" && r.isEmpty
                XCTAssertTrue(Self.refused(r) || silent, "\(label), chunks of \(chunk): \(r)")
            }
        }
    }

    // MARK: Sixel

    private func sixel(_ body: String) -> [UInt8] { Array("\u{1b}Pq\(body)\u{1b}\\".utf8) }

    /// Twenty-odd digits overflowed SwiftTerm's number parser, which traps:
    /// Portside crashed with every session in it. If the guard misses, this
    /// test doesn't fail, the test run dies.
    func testALongNumberNoLongerCrashes() {
        for body in ["#0!99999999999999999999999~", "#99999999999999999999999", "#0;2;99999999999999999999;0;0",
                     // SwiftTerm drops DEL, so these four runs of six are one number.
                     "#0!999999\u{7f}999999\u{7f}999999\u{7f}999999~"] {
            for chunk in [1, 5, .max] {
                let harness = guarded(sixel(body), chunk: chunk)
                XCTAssertLessThanOrEqual(harness.bitmaps.first?.width ?? 0, TerminalImageGuard.maxSixelWidth, body)
            }
        }
    }

    /// `!200000000~` asked for a 200-million-pixel row: gigabytes allocated
    /// and the main thread busy for minutes. Now cropped.
    func testAHugeRepeatIsCropped() throws {
        let harness = guarded(sixel("#0!200000~"))
        // The crop drops the whole run, leaving nothing painted; SwiftTerm 2
        // emits no bitmap for that (1.x emitted an empty one).
        XCTAssertLessThanOrEqual(harness.bitmaps.first?.width ?? 0, TerminalImageGuard.maxSixelWidth)
    }

    func testManySmallRepeatsCannotAddUpPastTheCap() throws {
        let harness = guarded(sixel("#0" + String(repeating: "!4000~", count: 50)))
        let size = try XCTUnwrap(harness.bitmaps.first)
        XCTAssertLessThanOrEqual(size.width, TerminalImageGuard.maxSixelWidth)
        XCTAssertGreaterThan(size.width, 0, "cropped, not refused")
    }

    func testATallImageIsCropped() throws {
        let harness = guarded(sixel("#0~" + String(repeating: "-~", count: 5000)))
        let size = try XCTUnwrap(harness.bitmaps.first)
        XCTAssertLessThanOrEqual(size.height, TerminalImageGuard.maxSixelHeight)
    }

    /// A repeat whose count can't be read is ignored by SwiftTerm and keeps
    /// the one before it; the guard has to keep the larger one too.
    func testARepeatCannotBeHiddenBehindAnUnreadableOne() throws {
        let harness = guarded(sixel("#0" + String(repeating: "!999999!\u{01}5~", count: 20)))
        // The crop drops the whole run, leaving nothing painted; SwiftTerm 2
        // emits no bitmap for that (1.x emitted an empty one).
        XCTAssertLessThanOrEqual(harness.bitmaps.first?.width ?? 0, TerminalImageGuard.maxSixelWidth)
    }

    /// Raster attributes (`"Pan;Pad;Ph;Pv`) declare a size. SwiftTerm sizes
    /// the bitmap from the pixels actually drawn, and since 2.0 refuses an
    /// image whose declaration is past its own pixel limit outright. Either
    /// way a huge declaration must not grow the bitmap — this pins that, so a
    /// SwiftTerm bump that starts honouring the declaration fails here first.
    func testDeclaredRasterSizeDoesNotSizeTheBitmap() {
        let harness = guarded(sixel("\"1;1;50000;50000#0~~"))
        XCTAssertLessThanOrEqual(harness.bitmaps.first?.width ?? 0, TerminalImageGuard.maxSixelWidth)
        XCTAssertLessThanOrEqual(harness.bitmaps.first?.height ?? 0, TerminalImageGuard.maxSixelHeight)
        let unguarded = TerminalHarness()
        unguarded.feed(sixel("\"1;1;50000;50000#0~~"))
        XCTAssertTrue(unguarded.bitmaps.isEmpty, "SwiftTerm refuses a declaration past its limit")
        let modest = TerminalHarness()
        modest.feed(sixel("\"1;1;3000;3000#0~~"))
        XCTAssertEqual(modest.bitmaps.first?.width, 2, "SwiftTerm ignores a declared size within its limit")
    }

    func testOrdinarySixelIsUntouched() {
        var filter = TerminalImageGuard()
        let body = sixel("#0;2;100;0;0#0!40~-!40~$#1!20N-#0~~~~")
        XCTAssertEqual(Array(filter.filtered(body[...])), body)
        let size = guarded(body).bitmaps.first
        XCTAssertEqual(size?.width, 40)
        XCTAssertEqual(size?.height, 18)
    }

    // MARK: Wiring

    /// The view applies it, and only to what the terminal gets: the transcript
    /// still records what arrived.
    @MainActor
    func testTheViewFiltersWhatTheTerminalSeesButNotTheLog() throws {
        let raw = apc("a=t,t=f,i=7", "/etc/hosts")
        let view = LoggingTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        var handed: [UInt8] = []
        view.onTerminalBytes = { handed = Array($0) }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-kitty-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        scratch.append(dir.path)
        let logger = try XCTUnwrap(SessionLogger(
            fileURL: dir.appendingPathComponent("view.log"), title: "t", subtitle: ""))
        view.logger = logger

        view.dataReceived(slice: raw[...])

        XCTAssertEqual(handed.count, raw.count)
        XCTAssertNotEqual(handed, raw)
        XCTAssertTrue(String(decoding: handed, as: UTF8.self).contains("t=X"))
        let control = try XCTUnwrap(SessionLogger(
            fileURL: dir.appendingPathComponent("control.log"), title: "t", subtitle: ""))
        control.append(raw[...])
        _ = logger.settledOffset()
        _ = control.settledOffset()
        XCTAssertEqual(try Data(contentsOf: logger.fileURL), try Data(contentsOf: control.fileURL),
                       "the log records the bytes as they arrived")
    }

    /// A status request (DECRQSS) carrying a non-ASCII byte crashed SwiftTerm.
    /// Every byte value, through the guard: if one still crashes, the test
    /// run dies here.
    func testAStatusRequestWithAnyByteDoesNotCrash() {
        for byte in UInt8(0x80)...UInt8(0xFF) {
            for chunk in [1, .max] {
                let bytes = Array("\u{1b}P$q".utf8) + [byte] + Array("m\u{1b}\\".utf8)
                _ = guarded(bytes, chunk: chunk)
            }
        }
    }

    func testAnOrdinaryStatusRequestStillGetsItsReply() {
        let reply = String(decoding: guarded(Array("\u{1b}P$qm\u{1b}\\".utf8)).replies, as: UTF8.self)
        XCTAssertTrue(reply.contains("$r"), reply.debugDescription)
    }

    /// An emoji in a window title, split at every possible byte: the same
    /// title and the same screen as all at once. Unguarded, a read starting
    /// on the emoji's second byte was taken for a C1 control.
    func testAnEmojiTitleSurvivesAnySplit() {
        // Ü is C3 9C: its second byte is also C1 ST, which mustn't end the
        // title before the emoji after it.
        let bytes = Array("\u{1b}]0;\u{DC} \u{1F680} deploy \u{1F467}\u{07}after".utf8)
        let whole = guarded(bytes)
        for split in 1..<bytes.count {
            var filter = TerminalImageGuard()
            let h = TerminalHarness()
            h.feed(Array(filter.filtered(bytes[..<split])))
            h.feed(Array(filter.filtered(bytes[split...])))
            XCTAssertEqual(h.titles.last, "\u{DC} \u{1F680} deploy \u{1F467}", "split at \(split)")
            XCTAssertEqual(h.screen, whole.screen, "split at \(split)")
            XCTAssertEqual(h.cursor.x, whole.cursor.x, "split at \(split)")
        }
    }

    /// Held bytes are only ever delayed: everything fed comes out, in order.
    func testNothingIsLostOrReordered() {
        let bytes = Array("x\u{1b}]0;\u{65E5}\u{672C}\u{1F680}\u{07}y\u{1b}_Ga=q;e\u{1b}\\z\u{1F680}".utf8)
        for size in 1...7 {
            var filter = TerminalImageGuard()
            var out: [UInt8] = []
            var i = 0
            while i < bytes.count {
                out += filter.filtered(bytes[i..<min(i + size, bytes.count)])
                i += size
            }
            XCTAssertEqual(out, bytes, "chunks of \(size)")
        }
    }

    /// Kitty commands are ASCII. Anything else inside an APC is replaced, so
    /// SwiftTerm 2 — which reads such a byte as content or as a control
    /// depending on where the read split — reads it the same way the guard does.
    func testNonASCIIInsideAnAPCIsReplaced() {
        var filter = TerminalImageGuard()
        let bytes = Array("\u{1b}_Ga=q;\u{00E9}".utf8) + [0x9F] + Array("\u{00DC}\u{1b}\\\u{00E9}".utf8)
        let expected = Array("\u{1b}_Ga=q;XXXXX\u{1b}\\\u{00E9}".utf8)
        XCTAssertEqual(Array(filter.filtered(bytes[...])), expected)
    }

    /// A C1 ST on its own ends an APC, and keeps ending it wherever the read
    /// splits; the same byte finishing `Ü` (C3 9C) doesn't.
    func testAC1STEndsAnAPCButTheSecondByteOfUDoesNot() {
        let bytes = Array("\u{1b}_Ga=q;\u{00DC}".utf8) + [0x9C] + Array("after".utf8)
        var filter = TerminalImageGuard()
        XCTAssertEqual(Array(filter.filtered(bytes[...])),
                       Array("\u{1b}_Ga=q;XX".utf8) + [0x07] + Array("after".utf8))
        for split in 1..<bytes.count {
            var filter = TerminalImageGuard()
            let h = TerminalHarness()
            h.feed(Array(filter.filtered(bytes[..<split])))
            h.feed(Array(filter.filtered(bytes[split...])))
            XCTAssertEqual(h.screen.first, "after", "split at \(split)")
        }
    }

    /// In an OSC a C1 byte that isn't continuing a character becomes `?`;
    /// characters and a C1 ST that ends the OSC are left alone.
    func testAStrayC1InsideAnOSCIsReplaced() {
        var filter = TerminalImageGuard()
        let bytes = Array("\u{1b}]0;a".utf8) + [0x9D, 0x90] + Array("\u{00DC}".utf8) + [0x9C]
        let expected = Array("\u{1b}]0;a??\u{00DC}".utf8) + [0x9C]
        XCTAssertEqual(Array(filter.filtered(bytes[...])), expected)
    }
}
