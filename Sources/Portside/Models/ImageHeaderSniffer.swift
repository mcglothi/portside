import Foundation

/// Reads an image's pixel size from the start of its bytes, as they arrive,
/// and decides whether it may be shown.
///
/// SwiftTerm hands an iTerm2 inline image to `NSImage` and draws it at its
/// native size when no size is requested, with no limit: a few hundred
/// kilobytes of PNG claiming a large size made Portside allocate gigabytes,
/// and a larger one could get it killed by macOS with every session in it.
/// Explicit size requests are already capped by SwiftTerm at about 4096
/// pixels; this applies the same bound to the image itself.
///
/// Allowed: PNG and JPEG, whose image sizes sit in their headers, up to
/// `maxDimension` a side. Everything else is refused: `NSImage` decodes many
/// more formats than anyone sends to a terminal, and each is more decoder
/// surface reachable from a remote host.
struct ImageHeaderSniffer {
    enum Verdict: Equatable { case undecided, allow, refuse }

    static let maxDimension = 4096
    /// How far into a JPEG to look for its frame header before giving up.
    /// EXIF and ICC segments come first and can run to a few hundred KB.
    static let jpegScanLimit = 1 << 20

    private(set) var verdict = Verdict.undecided
    private var header: [UInt8] = []
    private var count = 0
    private var jpeg = JPEGWalk()

    /// Feeds one decoded byte; returns the verdict once there is one.
    mutating func feed(_ byte: UInt8) -> Verdict {
        guard verdict == .undecided else { return verdict }
        count += 1
        if header.count < 24 { header.append(byte) }

        if header.count >= 3, header[0] == 0xFF, header[1] == 0xD8, header[2] == 0xFF {
            if count > 2 {
                switch jpeg.feed(byte) {
                case .some(let size): verdict = Self.within(size)
                case .none where count > Self.jpegScanLimit: verdict = .refuse
                case .none: break
                }
            }
            return verdict
        }
        guard header.count >= 4 else { return verdict }
        if header.starts(with: [0x89, 0x50, 0x4E, 0x47]) {             // PNG: IHDR width, height
            guard header.count >= 24 else { return verdict }
            verdict = Self.within((Self.be32(header, 16), Self.be32(header, 20)))
        } else {
            // GIF included: its header gives only the canvas, and each frame
            // carries its own size further in, so the first bytes can't
            // bound it.
            verdict = .refuse
        }
        return verdict
    }

    private static func within(_ size: (Int, Int)) -> Verdict {
        (1...maxDimension).contains(size.0) && (1...maxDimension).contains(size.1) ? .allow : .refuse
    }

    private static func be32(_ b: [UInt8], _ at: Int) -> Int {
        Int(b[at]) << 24 | Int(b[at + 1]) << 16 | Int(b[at + 2]) << 8 | Int(b[at + 3])
    }

    /// Walks JPEG segments after SOI to the first frame header (SOFn).
    private struct JPEGWalk {
        enum Phase { case marker, code, length(Int, [UInt8]), skip(Int), frame([UInt8]) }
        var phase = Phase.code     // SOI's FF D8 is consumed; the third byte is FF

        /// (width, height) once the frame header is read; (0, 0) if the
        /// stream isn't a JPEG after all.
        mutating func feed(_ b: UInt8) -> (Int, Int)? {
            switch phase {
            case .marker:
                if b == 0xFF { phase = .code } else { return (0, 0) }
            case .code:
                switch b {
                case 0xFF: break                                    // fill byte
                case 0x01, 0xD0...0xD9: phase = .marker             // standalone markers
                case 0xC0...0xCF where b != 0xC4 && b != 0xC8 && b != 0xCC:
                    phase = .frame([])
                default: phase = .length(0, [])
                }
            case .length(_, var bytes):
                bytes.append(b)
                if bytes.count == 2 {
                    let length = Int(bytes[0]) << 8 | Int(bytes[1])
                    if length < 2 { return (0, 0) }
                    phase = length == 2 ? .marker : .skip(length - 2)
                } else {
                    phase = .length(0, bytes)
                }
            case .skip(let left):
                phase = left <= 1 ? .marker : .skip(left - 1)
            case .frame(var bytes):
                // length(2) precision(1) height(2) width(2)
                bytes.append(b)
                if bytes.count == 7 {
                    return (Int(bytes[5]) << 8 | Int(bytes[6]), Int(bytes[3]) << 8 | Int(bytes[4]))
                }
                phase = .frame(bytes)
            }
            return nil
        }
    }
}

/// Base64 decoded a character at a time, for sniffing a payload that is
/// still arriving.
struct StreamingBase64 {
    private var bits: UInt32 = 0
    private var bitCount = 0
    /// Set at `=` or any character outside the alphabet: SwiftTerm's decoder
    /// refuses such a payload whole, so nothing after it matters.
    private(set) var ended = false

    /// The byte this character completes, if any.
    mutating func feed(_ c: UInt8) -> UInt8? {
        guard !ended else { return nil }
        let value: UInt32
        switch c {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): value = UInt32(c - UInt8(ascii: "A"))
        case UInt8(ascii: "a")...UInt8(ascii: "z"): value = UInt32(c - UInt8(ascii: "a")) + 26
        case UInt8(ascii: "0")...UInt8(ascii: "9"): value = UInt32(c - UInt8(ascii: "0")) + 52
        case UInt8(ascii: "+"): value = 62
        case UInt8(ascii: "/"): value = 63
        default:
            ended = true
            return nil
        }
        bits = (bits << 6) | value
        bitCount += 6
        guard bitCount >= 8 else { return nil }
        bitCount -= 8
        return UInt8((bits >> UInt32(bitCount)) & 0xFF)
    }
}
