import Foundation

/// Rewrites the two image protocols a remote program could use against the
/// Mac, on the way into SwiftTerm.
///
/// **Kitty graphics** (`ESC _ G <keys> ; <payload> ESC \`) can name where the
/// image comes from: `t=d` sends it inline, but `t=f` and `t=t` give a *file
/// path* and `t=s` a POSIX shared-memory name, which the terminal opens
/// itself. That's meant for a program on the same machine as the terminal. In
/// Portside nearly every session is on another machine, and SwiftTerm opened
/// the path on the Mac regardless. Its replies told the remote program whether
/// any path existed ("bad path" vs "bad payload") and, by asking for raw
/// pixels of a given size at a given offset, the file's exact size. It read up
/// to 400 MB per request on the main thread, and `t=s` unlinked the
/// shared-memory object it named. The first byte of every `t` value other than
/// `d` now becomes `X`, which SwiftTerm refuses with "ENOTSUP: unsupported
/// transmission" before touching anything — the answer a terminal without
/// file transmission gives, so programs such as `kitten icat` fall back to
/// sending the image inline, and inline images keep working.
///
/// **Sixel** (`ESC P … q <data> ESC \`) is decoded with unchecked numbers.
/// About 30 bytes — a digit run long enough to overflow an `Int` — trapped
/// and took Portside down with every session in it, and `!200000000~` (a
/// 200-million-pixel repeat, 20 bytes) allocated gigabytes and hung the main
/// thread. Digit runs are cut at `maxDigits`, and once the image would grow
/// past `maxSixelWidth` × `maxSixelHeight` the rest of it, up to its
/// terminator, becomes NUL, which the decoder skips: the image is cropped
/// rather than refused.
///
/// Both rewrite bytes in place, so the total length never changes; the only
/// other thing it does is hold back a UTF-8 character a read split inside an
/// OSC or APC until the next read (see `filtered`).
///
/// Errs towards rewriting. It tracks SwiftTerm's parser loosely — "an APC
/// (or DCS) might be open" from its introducer until a byte that ends one —
/// and counts conservatively wherever the parser and it might disagree about
/// a byte (C0 controls, DEL, C1). A stray C1 byte in UTF-8 text can switch it
/// on outside a sequence; the cost is that, until the next ESC or BEL,
/// `,t=f` in plain text shows as `,t=X`, or a digit run past six digits loses
/// its tail.
struct TerminalImageGuard {
    static let refusedMedium = UInt8(ascii: "X")
    static let maxDigits = 6
    static let maxSixelWidth = 4096
    static let maxSixelHeight = 4096


    fileprivate struct Sixel {
        var x = 0
        var y = 0
        var reps = 1
        /// Digits after `!`, while they're still arriving.
        var pendingReps: Int?
        var digitRun = 0
        var cropped = false
    }

    private enum State {
        case ground
        case escape
        case apc(KittyCommand)
        case dcsEntry
        case sixel(Sixel)
        case otherDCS
        /// Inside an OSC (`ESC ]`): titles, OSC 7, OSC 8, OSC 133 and the
        /// like. Tracked for UTF-8 split across reads (see `filtered`), and
        /// for iTerm2 inline images (`OSC 1337 ; File=… : <base64>`), whose
        /// size is checked before SwiftTerm decodes them.
        case osc(InlineImage)
    }

    /// Where an OSC is in `1337 ; File = <args> : <payload>`.
    fileprivate struct InlineImage {
        enum Phase { case number(Int), key([UInt8]), args, payload, other }
        var phase = Phase.number(0)
        var base64 = StreamingBase64()
        var sniffer = ImageHeaderSniffer()
    }

    /// Bytes held back from the end of the last read: the start of a UTF-8
    /// character that a read split, inside an OSC or APC.
    private var held: [UInt8] = []
    /// Continuation bytes still due for a UTF-8 character begun inside an
    /// OSC or APC. Those bytes (0x80–0xBF) overlap C1 controls — `Ü` is
    /// `C3 9C`, and 9C is ST — but SwiftTerm reads them as text when they
    /// follow their lead byte in the same read, which holding back split
    /// characters guarantees. So they're text here too.
    private var continuationsDue = 0
    /// The transfer SwiftTerm is holding between dispatched `m=1` commands.
    /// Even a raw or already accepted image needs a marker: continuation keys
    /// do not start a new image. Aborted APCs leave this state untouched.
    fileprivate var kittyCarry: KittyCommand.Pending?
    private var apcCount = 0

    private var state = State.ground

    /// The filtered bytes, or `slice` itself when nothing needed changing.
    ///
    /// One thing besides rewriting: inside an OSC or APC, a UTF-8 character
    /// that a read cut in two is held back and sent with the next read.
    /// SwiftTerm reads a continuation byte that *starts* a read there as a C1
    /// control rather than as text, so an emoji in a window title came out
    /// differently depending on where the pty's reads happened to split — a
    /// garbled title, a moved cursor. Nothing is changed or dropped; at most
    /// three bytes wait for the next read, which an OSC still in progress
    /// will send.
    mutating func filtered(_ slice: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        var input = slice
        if !held.isEmpty {
            input = (held + slice)[...]
            held = []
        }
        var copy: [UInt8]?
        var end = input.endIndex
        for i in input.indices {
            if inString, let need = Self.utf8Length(input[i]), input.endIndex - i < need,
               input[(i + 1)...].allSatisfy({ $0 & 0xC0 == 0x80 }) {
                held = Array(input[i...])
                end = i
                break
            }
            if let rewritten = consume(input[i]) {
                if copy == nil { copy = Array(input) }
                copy![i - input.startIndex] = rewritten
            }
        }
        if let copy { return copy[..<(end - input.startIndex)] }
        return input[..<end]
    }

    /// A UTF-8 continuation byte inside a string: content to the string's
    /// own parser, never a control.
    private mutating func stringContent(_ byte: UInt8) -> UInt8? {
        switch state {
        case .osc(var image):
            defer { state = .osc(image) }
            return image.consume(byte)
        case .apc(var command):
            defer { state = .apc(command) }
            return command.consume(byte, carry: kittyCarry)
        default:
            return nil
        }
    }

    private var inString: Bool {
        switch state {
        case .osc, .apc: return true
        default: return false
        }
    }

    /// Bytes in the UTF-8 character `lead` starts, or nil if it doesn't
    /// start one of two or more.
    private static func utf8Length(_ lead: UInt8) -> Int? {
        switch lead {
        case 0xC2...0xDF: return 2
        case 0xE0...0xEF: return 3
        case 0xF0...0xF4: return 4
        default: return nil
        }
    }

    /// Advances over one byte; returns its replacement when it must change.
    private mutating func consume(_ byte: UInt8) -> UInt8? {
        var leaving: KittyCommand?
        if case .apc(let command) = state { leaving = command }
        let result = step(byte)
        if var leaving {
            if case .apc(let now) = state, now.serial == leaving.serial { return result }
            leaving.end(dispatched: byte == 0x1B || byte == 0x07 || byte == 0x9C,
                        carry: &kittyCarry)
        }
        return result
    }

    private mutating func newAPC() -> State {
        apcCount += 1
        return .apc(KittyCommand(serial: apcCount))
    }

    private mutating func step(_ byte: UInt8) -> UInt8? {
        if continuationsDue > 0 {
            if byte & 0xC0 == 0x80 {
                continuationsDue -= 1
                return stringContent(byte)
            }
            continuationsDue = 0
        }
        if inString, let length = Self.utf8Length(byte) { continuationsDue = length - 1 }
        switch byte {
        case 0x1B:                          // ESC: ends a sequence, may start one
            state = .escape
            return nil
        case 0x07:                          // BEL ends an APC or OSC; a DCS stores it
            if inString { state = .ground }
            return nil
        case 0x18, 0x1A, 0x9C:              // CAN, SUB, ST
            state = .ground
            return nil
        case 0x9F:                          // C1 APC
            state = newAPC()
            return nil
        case 0x9D:                          // C1 OSC
            state = .osc(InlineImage())
            return nil
        case 0x90:                          // C1 DCS
            state = .dcsEntry
            return nil
        case 0x80...0x9F:                   // other C1 transitions abort an APC
            if case .apc = state { state = .ground }
            return nil
        default:
            break
        }

        switch state {
        case .ground, .otherDCS:
            return nil

        case .osc(var image):
            defer { state = .osc(image) }
            return image.consume(byte)

        case .escape:
            // SwiftTerm executes C0 controls and ignores DEL without leaving
            // the escape state, so `ESC ^A _` still opens an APC.
            if byte < 0x20 || byte == 0x7F { return nil }
            switch byte {
            case UInt8(ascii: "_"): state = newAPC()
            case UInt8(ascii: "P"): state = .dcsEntry
            case UInt8(ascii: "]"): state = .osc(InlineImage())
            default: state = .ground
            }
            return nil

        case .dcsEntry:
            // Parameters and intermediates until the final byte. Any DCS
            // ending in `q` is treated as sixel, intermediates or not.
            if (0x40...0x7E).contains(byte) {
                state = byte == UInt8(ascii: "q") ? .sixel(Sixel()) : .otherDCS
            }
            return nil

        case .apc(var command):
            guard byte >= 0x20 else { return nil }   // SwiftTerm drops C0 inside an APC
            defer { state = .apc(command) }
            return command.consume(byte, carry: kittyCarry)

        case .sixel(var sixel):
            defer { state = .sixel(sixel) }
            return sixel.consume(byte)
        }
    }
}

private extension TerminalImageGuard.Sixel {
    /// Mirrors the size pass of SwiftTerm's `SixelDcsHandler`, rounding every
    /// doubt upwards.
    mutating func consume(_ byte: UInt8) -> UInt8? {
        if cropped { return 0 }
        // The same DCS final carries a status request (DECRQSS, `$q`), whose
        // handler reads its text as ASCII and crashed on anything else. Nothing
        // legitimate in either is non-ASCII, so it becomes NUL, which both skip.
        if byte >= 0xA0 { return 0 }
        // Only printable ASCII is certainly stored and certainly not a digit.
        // C0 controls are stored but DEL is dropped, and C1 or UTF-8 bytes
        // may leave the sequence; none of them is trusted to end a number.
        guard (0x20...0x7E).contains(byte) else { return nil }

        if (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) {
            digitRun += 1
            if digitRun > TerminalImageGuard.maxDigits { return 0 }
            if let pending = pendingReps {
                pendingReps = pending * 10 + Int(byte - UInt8(ascii: "0"))
            }
            return nil
        }
        digitRun = 0
        if let pending = pendingReps {
            reps = max(reps, pending)
            pendingReps = nil
        }

        switch byte {
        case UInt8(ascii: "!"):
            pendingReps = 0
        case UInt8(ascii: "$"):
            x = 0
        case UInt8(ascii: "-"):
            y += 6
            x = 0
            if y + 6 > TerminalImageGuard.maxSixelHeight { cropped = true; return 0 }
        case 63...126:
            x += reps
            reps = 1
            if x > TerminalImageGuard.maxSixelWidth { cropped = true; return 0 }
        default:
            break
        }
        return nil
    }
}

private extension TerminalImageGuard.InlineImage {
    static let refused = UInt8(ascii: "=")

    /// Follows SwiftTerm's own reading: the OSC number before the first `;`,
    /// the key before the first `=`, the payload after the first `:`. C0
    /// controls inside an OSC are dropped by SwiftTerm, so they're skipped
    /// here too. Once the sniffer refuses, the byte that decided it becomes
    /// `=` — padding in the middle, which SwiftTerm's strict base64 decode
    /// rejects, so the image is never built.
    mutating func consume(_ byte: UInt8) -> UInt8? {
        guard byte >= 0x20 else { return nil }
        switch phase {
        case .number(let n):
            if (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) {
                phase = .number(min(n * 10 + Int(byte - UInt8(ascii: "0")), 1_000_000))
            } else {
                phase = byte == UInt8(ascii: ";") && n == 1337 ? .key([]) : .other
            }
        case .key(var key):
            if byte == UInt8(ascii: "=") {
                phase = key == Array("File".utf8) ? .args : .other
            } else if key.count < 16 {
                key.append(byte)
                phase = .key(key)
            } else {
                phase = .other
            }
        case .args:
            if byte == UInt8(ascii: ":") { phase = .payload }
        case .payload:
            guard sniffer.verdict == .undecided, let decoded = base64.feed(byte) else { return nil }
            if sniffer.feed(decoded) == .refuse { return Self.refused }
        case .other:
            break
        }
        return nil
    }
}

/// One Kitty command. Values are committed at a delimiter, just as SwiftTerm's
/// ASCII dictionary parser does: the last ASCII value wins, including empty or
/// invalid numbers, while a non-ASCII value does not replace an earlier entry.
/// No key/value or image payload is buffered here.
fileprivate struct KittyCommand {
    struct Check {
        var base64 = StreamingBase64(skipsUnknown: true)
        var sniffer = ImageHeaderSniffer()
        var refusing = false

        mutating func consume(_ byte: UInt8) -> UInt8? {
            if refusing { return UInt8(ascii: "=") }
            guard sniffer.verdict == .undecided else { return nil }
            if let decoded = base64.feed(byte) {
                refusing = sniffer.feed(decoded) == .refuse
            } else if base64.ended {
                refusing = true
            }
            // Remove the entire suffix, including subsequent chunks. A decoder
            // that ignores internal padding still cannot recover that suffix.
            // The retained prefix ends before the deciding header byte.
            return refusing ? UInt8(ascii: "=") : nil
        }
    }

    struct Pending {
        var check: Check?
    }

    /// Constant-space equivalent of Int(raw) for an ASCII decimal value.
    /// Accumulate negatively so Int.min is representable, and keep scanning
    /// after overflow so a later non-ASCII byte can discard the whole value.
    struct Value {
        var first: UInt8?
        var ascii = true
        var negative = false
        var digits = false
        var valid = true
        var number = 0

        mutating func feed(_ byte: UInt8) {
            let isFirst = first == nil
            if isFirst { first = byte }
            ascii = ascii && byte < 0x80
            if isFirst && (byte == UInt8(ascii: "+") || byte == UInt8(ascii: "-")) {
                negative = byte == UInt8(ascii: "-")
                return
            }
            guard valid, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) else { valid = false; return }
            digits = true
            let (scaled, mulOverflow) = number.multipliedReportingOverflow(by: 10)
            let (next, subOverflow) = scaled.subtractingReportingOverflow(Int(byte - UInt8(ascii: "0")))
            number = next
            valid = !mulOverflow && !subOverflow
        }

        var integer: Int? {
            guard valid, digits, negative || number != Int.min else { return nil }
            return negative ? number : -number
        }
    }

    enum Phase { case command, key([UInt8]), value(key: [UInt8], raw: Value, size: Int), payload, other }
    let serial: Int
    var phase = Phase.command
    var format = 32
    var more = 0
    var action = UInt8(ascii: "t")
    var medium = UInt8(ascii: "d")
    var compressed = false
    var transfer = Pending()

    init(serial: Int) { self.serial = serial }

    mutating func consume(_ byte: UInt8, carry: Pending?) -> UInt8? {
        switch phase {
        case .command:
            phase = byte == UInt8(ascii: "G") ? .key([]) : .other
        case .key(var key):
            switch byte {
            case UInt8(ascii: "="): phase = .value(key: key, raw: Value(), size: 0)
            case UInt8(ascii: ","): phase = .key([])
            case UInt8(ascii: ";"): startPayload(carry: carry)
            default:
                // All interesting keys have length one. Retain a second byte
                // only to distinguish an unknown longer key, however long.
                if key.count < 2 { key.append(byte) }
                phase = .key(key)
            }
        case .value(let key, var raw, var size):
            if byte == UInt8(ascii: ",") || byte == UInt8(ascii: ";") {
                finishValue(key, raw)
                if byte == UInt8(ascii: ",") { phase = .key([]) } else { startPayload(carry: carry) }
                return nil
            }
            var replacement: UInt8?
            if key == [UInt8(ascii: "t")], raw.first == nil, byte != UInt8(ascii: "d") { replacement = UInt8(ascii: "X") }
            if key == [UInt8(ascii: "s")] || key == [UInt8(ascii: "v")], (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte), size >= 0 {
                size = size * 10 + Int(byte - UInt8(ascii: "0"))
                if size > ImageHeaderSniffer.maxDimension { replacement = UInt8(ascii: "X"); size = -1 }
            }
            // Track what SwiftTerm receives, including the existing t=X refusal.
            raw.feed(replacement ?? byte)
            phase = .value(key: key, raw: raw, size: size)
            return replacement
        case .payload:
            return transfer.check?.consume(byte)
        case .other:
            break
        }
        return nil
    }

    private mutating func finishValue(_ key: [UInt8], _ value: Value) {
        guard value.ascii else { return }
        switch key {
        case [UInt8(ascii: "f")]: format = value.integer ?? 32  // f
        case [UInt8(ascii: "m")]: more = value.integer ?? 0     // m
        case [UInt8(ascii: "a")]: action = value.first ?? UInt8(ascii: "t")    // a, default t
        case [UInt8(ascii: "t")]: medium = value.first ?? UInt8(ascii: "d")   // t, default d
        case [UInt8(ascii: "o")]: compressed = value.first != nil // o
        default: break
        }
    }

    private mutating func startPayload(carry: Pending?) {
        phase = .payload
        let deleting = action == UInt8(ascii: "d") || action == UInt8(ascii: "D")
        if let carry, !deleting {
            transfer = carry
        } else if format == 100 && medium == UInt8(ascii: "d") {
            var check = Check()
            check.refusing = compressed
            transfer = Pending(check: check)
        }
    }

    mutating func end(dispatched: Bool, carry: inout Pending?) {
        // CAN/SUB and other APC aborts never reach handleKittyGraphics.
        guard dispatched else { return }
        switch phase {
        case .command, .other: return
        case .value(let key, let raw, _):
            finishValue(key, raw)
            startPayload(carry: carry)
        case .key:
            startPayload(carry: carry) // no semicolon: an empty payload
        case .payload: break
        }
        // SwiftTerm first clears pending on a=d/D, then appends/starts only
        // for m=1 with t=d. Every other dispatched Kitty command finishes it.
        carry = more == 1 && medium == UInt8(ascii: "d") ? transfer : nil
    }
}
