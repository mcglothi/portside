import Foundation

/// How Portside treats the previous session's open tabs on launch.
enum RestoreMode: String, Codable, CaseIterable, Identifiable {
    case off, ask, auto
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Don't restore"
        case .ask: return "Ask each launch"
        case .auto: return "Restore automatically"
        }
    }
}

/// Terminal *behavior* (as opposed to look — see `TerminalAppearance`),
/// persisted in the library and applied to every live terminal.
struct TerminalSettings: Equatable {
    /// Scrollback buffer size in lines. SwiftTerm defaults to a stingy 500;
    /// operators reading long build/log output want far more.
    var scrollbackLines: Int = 10_000

    /// Opt-in GPU (Metal) rendering. Off by default: it's SwiftTerm's newer path
    /// and we haven't benchmarked it enough to make it the default. Falls back to
    /// CoreGraphics automatically if Metal is unavailable (e.g. in a VM).
    var useMetalRenderer: Bool = false

    /// Whether to reopen the last session's tabs on launch. Defaults to `ask`:
    /// safe and discoverable without silently reconnecting.
    var restoreMode: RestoreMode = .ask

    /// Presets offered in Settings. Bounded on purpose: SwiftTerm has no true
    /// "unlimited" mode (passing nil *disables* scrollback), and each line is a
    /// preallocated slot, so we cap at a large-but-sane ceiling.
    static let scrollbackOptions = [1_000, 5_000, 10_000, 50_000, 100_000]

    /// Clamped to the supported range so a hand-edited library can't ask
    /// SwiftTerm to disable scrollback (0/negative) or allocate absurdly.
    var resolvedScrollback: Int {
        min(max(scrollbackLines, 100), 100_000)
    }
}

// Tolerant Codable so a library written with an earlier field set (e.g. only
// scrollbackLines) keeps loading as new terminal settings are added.
extension TerminalSettings: Codable {
    enum CodingKeys: String, CodingKey {
        case scrollbackLines, useMetalRenderer, restoreMode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = TerminalSettings()
        scrollbackLines = try c.decodeIfPresent(Int.self, forKey: .scrollbackLines) ?? defaults.scrollbackLines
        useMetalRenderer = try c.decodeIfPresent(Bool.self, forKey: .useMetalRenderer) ?? defaults.useMetalRenderer
        restoreMode = try c.decodeIfPresent(RestoreMode.self, forKey: .restoreMode) ?? defaults.restoreMode
    }
}
