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
    /// (`0.36.0` < `0.36.1` < `0.37.0`). Anything unreadable compares as
    /// not newer, so a malformed stamp can't block a publish.
    static func isNewer(_ a: String, than b: String) -> Bool {
        // Every part a plain unsigned number: `split` would drop the empty
        // part of ".40" and Int() would take "-1", turning a mangled stamp
        // into a version that blocks a publish.
        func parts(_ v: String) -> [Int]? {
            let p = v.split(separator: ".", omittingEmptySubsequences: false)
            guard !p.isEmpty, p.allSatisfy({ !$0.isEmpty && $0.count <= 9 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) })
            else { return nil }
            return p.compactMap { Int($0) }
        }
        guard let x = parts(a), let y = parts(b) else { return false }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}
