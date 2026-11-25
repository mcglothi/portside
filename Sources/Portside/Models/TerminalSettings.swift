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
/// What a click in the scroll bar's track does. macOS has a system-wide
/// choice for this (Appearance › "Click in the scroll bar to"); `system`
/// follows it, the other two override it for terminals only.
enum ScrollbarClickBehavior: String, Codable, CaseIterable, Identifiable {
    case system, page, spot
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "Follow System Settings"
        case .page: return "Jump to the next page"
        case .spot: return "Jump to the spot that's clicked"
        }
    }
}

/// How the mouse copies and pastes in a terminal. ⌘C/⌘V work in both.
/// `selectToCopy` is the X11/PuTTY habit: finishing a selection copies it,
/// and a right-click pastes instead of opening the Copy/Paste menu.
enum ClipboardStyle: String, Codable, CaseIterable, Identifiable {
    case mac, selectToCopy
    var id: String { rawValue }
    var label: String {
        switch self {
        case .mac: return "Mac (⌘C / ⌘V, right-click menu)"
        case .selectToCopy: return "Select to copy, right-click to paste"
        }
    }
}

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

    /// Type the shell integration into each new ssh session instead of asking
    /// to append it to the host's `.bashrc`/`.zshrc` — see
    /// `ShellIntegrationInjection`. Off by default: it writes a line of shell
    /// into every session on connect, which is visible in the scrollback and
    /// is not something to start doing to someone's hosts unasked.
    var injectShellIntegration: Bool = false

    /// Page or jump on a click in the terminal scroll bar's track.
    var scrollbarClick: ScrollbarClickBehavior = .system

    /// Mac-style clipboard by default; select-to-copy is opt-in.
    var clipboardStyle: ClipboardStyle = .mac

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
        case scrollbackLines, useMetalRenderer, restoreMode, injectShellIntegration, scrollbarClick, clipboardStyle
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = TerminalSettings()
        scrollbackLines = try c.decodeIfPresent(Int.self, forKey: .scrollbackLines) ?? defaults.scrollbackLines
        useMetalRenderer = try c.decodeIfPresent(Bool.self, forKey: .useMetalRenderer) ?? defaults.useMetalRenderer
        restoreMode = try c.decodeIfPresent(RestoreMode.self, forKey: .restoreMode) ?? defaults.restoreMode
        injectShellIntegration = try c.decodeIfPresent(Bool.self, forKey: .injectShellIntegration)
            ?? defaults.injectShellIntegration
        // try?: a value a newer build wrote mustn't fail the whole settings load.
        scrollbarClick = (try? c.decodeIfPresent(ScrollbarClickBehavior.self, forKey: .scrollbarClick))
            ?? defaults.scrollbarClick
        clipboardStyle = (try? c.decodeIfPresent(ClipboardStyle.self, forKey: .clipboardStyle))
            ?? defaults.clipboardStyle
    }
}
