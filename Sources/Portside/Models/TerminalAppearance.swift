import AppKit
import SwiftTerm

/// Global, app-wide terminal look: font plus foreground/background/cursor and
/// the 16-color ANSI palette. Persisted in the session library and applied to
/// every live terminal (see `SessionManager.applyAppearance`). The palette is
/// stored inline (not by name) so imported themes survive.
struct TerminalAppearance: Equatable {
    var fontName: String = "Menlo"
    var fontSize: Double = Double(NSFont.systemFontSize)
    var themeName: String
    var foregroundHex: String
    var backgroundHex: String
    var cursorHex: String
    var ansiHex: [String]   // exactly 16 hex values, ANSI order

    static let `default` = TerminalTheme.systemDefault.appearance()

    var palette: [SwiftTerm.Color] { ansiHex.map { HexColor.terminalColor($0) } }

    var nsFont: NSFont {
        NSFont(name: fontName, size: fontSize) ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    var foreground: NSColor { HexColor.nsColor(foregroundHex) }
    var background: NSColor { HexColor.nsColor(backgroundHex) }
    var cursor: NSColor { HexColor.nsColor(cursorHex) }

    /// The current colors as a theme, e.g. for previews.
    var asTheme: TerminalTheme {
        TerminalTheme(name: themeName, foreground: foregroundHex, background: backgroundHex,
                      cursor: cursorHex, ansi: ansiHex)
    }

    /// Swaps in a theme's colors while keeping the current font.
    func applying(_ theme: TerminalTheme) -> TerminalAppearance {
        var copy = self
        copy.themeName = theme.name
        copy.foregroundHex = theme.foreground
        copy.backgroundHex = theme.background
        copy.cursorHex = theme.cursor
        copy.ansiHex = theme.ansi
        return copy
    }
}

// Tolerant Codable so appearance files written before the palette moved inline
// (or before themes existed) keep loading instead of wiping the library.
extension TerminalAppearance: Codable {
    enum CodingKeys: String, CodingKey {
        case fontName, fontSize, themeName, paletteName
        case foregroundHex, backgroundHex, cursorHex, ansiHex
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = TerminalTheme.systemDefault
        fontName = try c.decodeIfPresent(String.self, forKey: .fontName) ?? "Menlo"
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? Double(NSFont.systemFontSize)
        let resolvedName = try c.decodeIfPresent(String.self, forKey: .themeName)
            ?? c.decodeIfPresent(String.self, forKey: .paletteName)
            ?? fallback.name
        themeName = resolvedName
        foregroundHex = try c.decodeIfPresent(String.self, forKey: .foregroundHex) ?? fallback.foreground
        backgroundHex = try c.decodeIfPresent(String.self, forKey: .backgroundHex) ?? fallback.background
        cursorHex = try c.decodeIfPresent(String.self, forKey: .cursorHex) ?? fallback.cursor
        let decodedAnsi = try c.decodeIfPresent([String].self, forKey: .ansiHex)
        ansiHex = (decodedAnsi?.count == 16 ? decodedAnsi : nil)
            ?? (TerminalTheme.builtIns.first { $0.name == resolvedName }?.ansi ?? fallback.ansi)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(fontName, forKey: .fontName)
        try c.encode(fontSize, forKey: .fontSize)
        try c.encode(themeName, forKey: .themeName)
        try c.encode(foregroundHex, forKey: .foregroundHex)
        try c.encode(backgroundHex, forKey: .backgroundHex)
        try c.encode(cursorHex, forKey: .cursorHex)
        try c.encode(ansiHex, forKey: .ansiHex)
    }
}

/// A named color scheme, used for both built-in presets and imported themes.
struct TerminalTheme: Codable, Identifiable, Equatable, Hashable {
    var id: String { name }
    var name: String
    var foreground: String
    var background: String
    var cursor: String
    var ansi: [String]   // exactly 16 hex values, ANSI order

    func appearance(font: String = "Menlo", size: Double = Double(NSFont.systemFontSize)) -> TerminalAppearance {
        TerminalAppearance(
            fontName: font, fontSize: size, themeName: name,
            foregroundHex: foreground, backgroundHex: background, cursorHex: cursor, ansiHex: ansi
        )
    }

    /// System Default plus the curated set bundled from
    /// mbadolato/iTerm2-Color-Schemes (regenerate with
    /// `Scripts/update_bundled_themes.py`). Falls back to the hardcoded trio
    /// if the resource bundle is missing (e.g. bare SPM binary moved out of
    /// the .app).
    static let builtIns: [TerminalTheme] = [systemDefault] + bundled

    /// Locates the SwiftPM resource bundle WITHOUT Bundle.module. The accessor
    /// SwiftPM generates for executable targets traps (fatalError → SIGTRAP)
    /// when the bundle is missing instead of returning nil, and it looks in
    /// the wrong place for a packaged .app: Bundle.main.bundleURL (the .app
    /// root) rather than Contents/Resources where make_app.sh puts it. Its
    /// only other candidate is the build machine's absolute .build path, so
    /// 0.7.0 opened Settings fine on the machine that built it and crashed
    /// on everyone else's.
    private static let resourceBundle: Bundle? = {
        let name = "Portside_Portside.bundle"
        let candidates = [
            Bundle.main.resourceURL,  // packaged .app: Contents/Resources
            Bundle.main.bundleURL,    // bare SPM binary: the executable's directory
        ]
        for base in candidates {
            if let base, let bundle = Bundle(url: base.appendingPathComponent(name)) {
                return bundle
            }
        }
        return nil
    }()

    private static let bundled: [TerminalTheme] = {
        guard let url = resourceBundle?.url(forResource: "BundledThemes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let themes = try? JSONDecoder().decode([TerminalTheme].self, from: data),
              !themes.isEmpty else {
            return [solarizedDark, dracula, nord]
        }
        return themes
    }()

    static let systemDefault = TerminalTheme(
        name: "System Default",
        foreground: "#E5E5E5", background: "#000000", cursor: "#FFFFFF",
        ansi: ["#000000", "#CD0000", "#00CD00", "#CDCD00", "#0000EE", "#CD00CD",
               "#00CDCD", "#E5E5E5", "#7F7F7F", "#FF0000", "#00FF00", "#FFFF00",
               "#5C5CFF", "#FF00FF", "#00FFFF", "#FFFFFF"]
    )

    static let solarizedDark = TerminalTheme(
        name: "Solarized Dark",
        foreground: "#839496", background: "#002B36", cursor: "#839496",
        ansi: ["#073642", "#DC322F", "#859900", "#B58900", "#268BD2", "#D33682",
               "#2AA198", "#EEE8D5", "#002B36", "#CB4B16", "#586E75", "#657B83",
               "#839496", "#6C71C4", "#93A1A1", "#FDF6E3"]
    )

    static let dracula = TerminalTheme(
        name: "Dracula",
        foreground: "#F8F8F2", background: "#282A36", cursor: "#F8F8F2",
        ansi: ["#21222C", "#FF5555", "#50FA7B", "#F1FA8C", "#BD93F9", "#FF79C6",
               "#8BE9FD", "#F8F8F2", "#6272A4", "#FF6E6E", "#69FF94", "#FFFFA5",
               "#D6ACFF", "#FF92DF", "#A4FFFF", "#FFFFFF"]
    )

    static let nord = TerminalTheme(
        name: "Nord",
        foreground: "#D8DEE9", background: "#2E3440", cursor: "#D8DEE9",
        ansi: ["#3B4252", "#BF616A", "#A3BE8C", "#EBCB8B", "#81A1C1", "#B48EAD",
               "#88C0D0", "#E5E9F0", "#4C566A", "#BF616A", "#A3BE8C", "#EBCB8B",
               "#81A1C1", "#B48EAD", "#8FBCBB", "#ECEFF4"]
    )

    enum ImportError: LocalizedError {
        case unrecognized
        var errorDescription: String? {
            "Unrecognized theme file. Import an iTerm2 .itermcolors file or a Portside .json theme."
        }
    }

    /// Parses either a Portside JSON theme or an iTerm2 `.itermcolors` plist.
    static func imported(from data: Data, name: String) throws -> TerminalTheme {
        if var theme = try? JSONDecoder().decode(TerminalTheme.self, from: data), theme.ansi.count == 16 {
            theme.name = name
            return theme
        }
        return try fromITermColors(data: data, name: name)
    }

    /// iTerm2 stores colors as a plist of {Red/Green/Blue Component: 0–1 floats}.
    private static func fromITermColors(data: Data, name: String) throws -> TerminalTheme {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any] else {
            throw ImportError.unrecognized
        }
        func hex(_ key: String) -> String? {
            guard let c = dict[key] as? [String: Any],
                  let r = c["Red Component"] as? Double,
                  let g = c["Green Component"] as? Double,
                  let b = c["Blue Component"] as? Double else { return nil }
            return String(format: "#%02X%02X%02X",
                          Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
        }
        var ansi: [String] = []
        for i in 0..<16 {
            guard let h = hex("Ansi \(i) Color") else { throw ImportError.unrecognized }
            ansi.append(h)
        }
        return TerminalTheme(
            name: name,
            foreground: hex("Foreground Color") ?? "#E5E5E5",
            background: hex("Background Color") ?? "#000000",
            cursor: hex("Cursor Color") ?? "#FFFFFF",
            ansi: ansi
        )
    }
}

/// #RRGGBB ⇄ NSColor / SwiftTerm.Color (which uses 16-bit channels).
enum HexColor {
    static func rgb(_ hex: String) -> (r: UInt8, g: UInt8, b: UInt8) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return (0, 0, 0) }
        return (UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF))
    }

    static func nsColor(_ hex: String) -> NSColor {
        let c = rgb(hex)
        return NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255,
                       blue: CGFloat(c.b) / 255, alpha: 1)
    }

    static func terminalColor(_ hex: String) -> SwiftTerm.Color {
        let c = rgb(hex)
        // SwiftTerm channels are 16-bit; scale 0–255 to 0–65535 (×257).
        return SwiftTerm.Color(red: UInt16(c.r) * 257, green: UInt16(c.g) * 257, blue: UInt16(c.b) * 257)
    }

    static func hex(from color: NSColor) -> String {
        guard let c = color.usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X",
                      Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }
}
