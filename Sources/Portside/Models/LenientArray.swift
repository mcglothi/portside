import Foundation

/// An array that drops elements it can't decode instead of failing.
///
/// A plain `[T]` fails the *whole* decode if any single element throws, and in
/// `SessionStore.Document` that means one malformed record takes the entire
/// library down — hosts, folders, macros, profiles, all of it — and sends the
/// file to quarantine. That is the shape of the 0.16 audit's data-loss P0, and
/// it is why every field on `Macro` and `SessionEntry` has a default and a
/// hand-written tolerant decoder.
///
/// Tolerant decoders only stretch so far, though: they cover a *missing* field
/// that has a sensible default, and some fields have none. A `SessionGroup`
/// without a layout is not a group, so it has to fail — and this is what keeps
/// that failure local to the one record.
///
/// The wrapper is what makes skipping work. A failed `decode` may leave the
/// unkeyed container's index where it was, so retrying would spin; `Failable`
/// never throws, so the container always advances exactly one element.
struct LenientArray<Element: Codable>: Codable, Equatable where Element: Equatable {
    var elements: [Element]

    init(_ elements: [Element]) { self.elements = elements }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var decoded: [Element] = []
        while !container.isAtEnd {
            let wrapped = try container.decode(Failable.self)
            if let value = wrapped.value {
                decoded.append(value)
            } else {
                NSLog("Portside: dropped one unreadable \(Element.self) while loading")
            }
        }
        elements = decoded
    }

    func encode(to encoder: Encoder) throws {
        try elements.encode(to: encoder)
    }

    private struct Failable: Decodable {
        let value: Element?
        init(from decoder: Decoder) throws {
            value = try? Element(from: decoder)
        }
    }
}
