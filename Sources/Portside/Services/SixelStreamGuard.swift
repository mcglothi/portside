import Foundation

/// Works around a crash in SwiftTerm's Sixel decoder, fixed upstream in
/// `58915b10` but not present in any released version — it landed two hours and
/// forty-six minutes after `v1.15.0` was tagged, and `v1.15.0` is what we pin.
///
/// `SixelDcsHandler` sizes the image in one pass and fills it in a second, but
/// the sizing pass only widens the image when it sees a band terminator (`$` or
/// `-`). A sixel whose *final* band is wider than every terminated band before
/// it is therefore measured too narrow, and the fill pass writes past the end of
/// the pixel buffer. That is a `fatalError`, so the app dies — from ordinary
/// output arriving over SSH, with no user action. Every single-band image of
/// width >= 2 hits it, and Portside advertises Sixel support in its device
/// attributes, so applications probe, find it, and send.
///
/// The workaround is to append the band terminator the encoder left off, so the
/// sizing pass measures the last band. This produces a byte-for-byte identical
/// image to the upstream fix: a trailing `-` advances `y` and folds `x` into
/// `maxX`, but writes no pixels, so `maxY` is unchanged. `SixelStreamGuardTests`
/// asserts that equivalence against a real `Terminal` rather than assuming it.
///
/// **Delete this once a SwiftTerm carrying `58915b10` is released** — it is
/// dead weight the moment the pin moves.
struct SixelStreamGuard {

    private enum State {
        /// Anywhere outside a sixel payload.
        case passthrough
        /// After `ESC P`, reading parameters and intermediates up to the final
        /// byte that says which DCS this is.
        case dcsPrologue
        /// Inside a sixel payload, where the injection decision gets made.
        case sixelBody
    }

    private var state: State = .passthrough
    /// An `ESC` we have consumed but not yet emitted. Held because the byte
    /// after it decides whether a terminator has to be injected *before* it,
    /// and that byte may not arrive until the next chunk.
    private var pendingESC = false
    /// Intermediates distinguish sixel (`ESC P q`) from DCS sequences that
    /// merely end in `q`, such as DECRQSS (`ESC P $ q`).
    private var sawIntermediate = false
    /// Whether pixel bytes have appeared since the last `$` or `-`. When this is
    /// true at the terminator, the final band is unmeasured and would crash.
    private var pixelsSinceBandBreak = false

    /// Feeds a chunk through, returning what should reach the terminal.
    ///
    /// Returns the input unchanged whenever nothing needs rewriting, which is
    /// every chunk in normal use — this sits on the hot path for all terminal
    /// output, so the common case must not allocate.
    mutating func filter(_ slice: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        if state == .passthrough, !pendingESC, !slice.contains(0x1B) {
            return slice
        }

        var out: [UInt8] = []
        out.reserveCapacity(slice.count + 1)
        for byte in slice {
            emit(byte, into: &out)
        }
        return out[...]
    }

    /// Abandons any sequence in progress and returns to plain passthrough.
    private mutating func abandonSequence() {
        state = .passthrough
        sawIntermediate = false
        pixelsSinceBandBreak = false
    }

    private mutating func emit(_ byte: UInt8, into out: inout [UInt8]) {
        // CAN and SUB cancel whatever is in progress, from *every* state.
        // SwiftTerm has it as a global "anywhere" rule:
        //
        //     table.add(codes: [0x18, 0x1a, 0x99, 0x9a], state: state,
        //               action: .execute, next: .ground)
        //
        // Staying in the DCS here while the terminal has gone back to ground is
        // how `ESC P CAN q ~~ ESC \` -- ordinary text as far as the terminal is
        // concerned -- got a `-` written into the middle of it. Found by Codex
        // CLI in the 0.17 pre-release review.
        if byte == 0x18 || byte == 0x1A {
            if pendingESC {
                out.append(0x1B)
                pendingESC = false
            }
            abandonSequence()
            out.append(byte)
            return
        }

        if pendingESC {
            pendingESC = false

            // ST closing a sixel payload: the one place a terminator is owed.
            if state == .sixelBody, byte == 0x5C {
                if pixelsSinceBandBreak { out.append(0x2D) }
                out.append(0x1B)
                out.append(byte)
                state = .passthrough
                return
            }

            out.append(0x1B)

            // `ESC P` opens a DCS.
            if state == .passthrough, byte == 0x50 {
                out.append(byte)
                state = .dcsPrologue
                sawIntermediate = false
                return
            }

            // Any other escape sequence abandons a sixel payload in progress.
            if state == .sixelBody || state == .dcsPrologue {
                state = .passthrough
            }

            if byte == 0x1B {
                pendingESC = true
                return
            }
            out.append(byte)
            return
        }

        if byte == 0x1B {
            pendingESC = true
            return
        }

        switch state {
        case .passthrough:
            out.append(byte)

        case .dcsPrologue:
            out.append(byte)
            switch byte {
            case 0x9C:
                // ST before a handler has even been selected ends the sequence;
                // there is no sixel body to owe a terminator to.
                abandonSequence()
            case 0x20...0x2F:
                sawIntermediate = true
            case 0x30...0x3F:
                break // parameter bytes
            case 0x40...0x7E:
                // The final byte names the DCS. Sixel is `q` with no
                // intermediates; DECRQSS is `$q` and must not be touched.
                if byte == 0x71 && !sawIntermediate {
                    state = .sixelBody
                    pixelsSinceBandBreak = false
                } else {
                    state = .passthrough
                }
            default:
                break
            }

        case .sixelBody:
            // 8-bit ST. Unambiguous here: a sixel payload is all ASCII.
            if byte == 0x9C {
                if pixelsSinceBandBreak { out.append(0x2D) }
                out.append(byte)
                state = .passthrough
                return
            }
            switch byte {
            case 0x24, 0x2D: // "$" carriage return, "-" new band
                pixelsSinceBandBreak = false
            case 63...126: // pixel data, the same range SwiftTerm plots on
                pixelsSinceBandBreak = true
            default:
                break // colour selection, repeat counts, raster attributes
            }
            out.append(byte)
        }
    }
}
