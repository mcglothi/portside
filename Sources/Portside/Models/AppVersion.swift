import Foundation

/// This build's version, and how two compare.
enum AppVersion {
    /// `CFBundleShortVersionString` of the Portside app, or nil for a
    /// development build (`swift run`, tests), which has no release to
    /// compare. Only Portside's own bundle counts: under XCTest the main
    /// bundle is the test runner, with a version of its own.
    static var current: String? {
        guard Bundle.main.bundleIdentifier == "net.timmcg.portside" else { return nil }
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// Whether `a` is a later release than `b`, comparing dotted numbers
    /// (`0.36.0` < `0.36.1` < `0.37.0`). A beta (`0.38.0-beta.2`) comes after
    /// the release before it and before its own release, so a beta's stamp
    /// stops an older stable build from publishing over it. Anything
    /// unreadable compares as not newer, so a malformed stamp can't block a
    /// publish.
    static func isNewer(_ a: String, than b: String) -> Bool {
        guard let x = parse(a), let y = parse(b) else { return false }
        for i in 0..<max(x.parts.count, y.parts.count) {
            let l = i < x.parts.count ? x.parts[i] : 0, r = i < y.parts.count ? y.parts[i] : 0
            if l != r { return l > r }
        }
        switch (x.beta, y.beta) {
        case let (l?, r?): return l > r
        case (nil, _?): return true
        default: return false
        }
    }

    /// Dotted numbers, optionally followed by `-beta.<n>` — the only suffix
    /// `release.sh --beta` cuts.
    private static func parse(_ v: String) -> (parts: [Int], beta: Int?)? {
        // Every part a plain unsigned number: `split` would drop the empty
        // part of ".40" and Int() would take "-1", turning a mangled stamp
        // into a version that blocks a publish.
        func number(_ s: Substring) -> Int? {
            guard !s.isEmpty, s.count <= 9, s.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(s)
        }
        let halves = v.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let parts = halves[0].split(separator: ".", omittingEmptySubsequences: false).map(number)
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        guard halves.count == 2 else { return (parts.compactMap { $0 }, nil) }
        guard halves[1].hasPrefix("beta."), let n = number(halves[1].dropFirst(5)) else { return nil }
        return (parts.compactMap { $0 }, n)
    }
}
