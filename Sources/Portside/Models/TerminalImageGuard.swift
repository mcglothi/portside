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
/// Both rewrite bytes in place, so the length never changes and nothing that
/// counts bytes moves.
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

    private enum Key { case none, sawT, sawEquals }

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
        case apc(previous: UInt8, key: Key)
        case dcsEntry
        case sixel(Sixel)
        case otherDCS
    }

    private var state = State.ground

    /// The filtered bytes, or `slice` itself when nothing needed changing.
    mutating func filtered(_ slice: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        var copy: [UInt8]?
        for i in slice.indices {
            if let rewritten = consume(slice[i]) {
                if copy == nil { copy = Array(slice) }
                copy![i - slice.startIndex] = rewritten
            }
        }
        return copy.map { $0[...] } ?? slice
    }

    /// Advances over one byte; returns its replacement when it must change.
    private mutating func consume(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x1B:                          // ESC: ends a sequence, may start one
            state = .escape
            return nil
        case 0x07:                          // BEL ends an APC; a DCS stores it
            if case .apc = state { state = .ground }
            return nil
        case 0x18, 0x1A, 0x9C:              // CAN, SUB, ST
            state = .ground
            return nil
        case 0x9F:                          // C1 APC
            state = .apc(previous: 0, key: .none)
            return nil
        case 0x90:                          // C1 DCS
            state = .dcsEntry
            return nil
        default:
            break
        }

        switch state {
        case .ground, .otherDCS:
            return nil

        case .escape:
            // SwiftTerm executes C0 controls and ignores DEL without leaving
            // the escape state, so `ESC ^A _` still opens an APC.
            if byte < 0x20 || byte == 0x7F { return nil }
            switch byte {
            case UInt8(ascii: "_"): state = .apc(previous: 0, key: .none)
            case UInt8(ascii: "P"): state = .dcsEntry
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

        case .apc(let previous, let key):
            guard byte >= 0x20 else { return nil }   // SwiftTerm drops C0 inside an APC
            var replacement: UInt8?
            var next = Key.none
            switch key {
            case .sawEquals:
                if byte != UInt8(ascii: "d"), byte != UInt8(ascii: ","), byte != UInt8(ascii: ";") {
                    replacement = Self.refusedMedium
                }
            case .sawT:
                if byte == UInt8(ascii: "=") { next = .sawEquals }
            case .none:
                // A key starts right after the `G` command byte or a comma.
                if byte == UInt8(ascii: "t"),
                   previous == UInt8(ascii: "G") || previous == UInt8(ascii: ",") {
                    next = .sawT
                }
            }
            state = .apc(previous: replacement ?? byte, key: next)
            return replacement

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
