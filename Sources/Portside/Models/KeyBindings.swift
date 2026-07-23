import SwiftUI

/// One modifier in a shortcut. Stored as a set rather than reusing SwiftUI's
/// `EventModifiers` directly since that type isn't `Codable`.
enum ModifierKey: String, Codable, CaseIterable {
    case command, shift, option, control

    var symbol: String {
        switch self {
        case .command: return "⌘"
        case .shift: return "⇧"
        case .option: return "⌥"
        case .control: return "⌃"
        }
    }

    var eventModifier: EventModifiers {
        switch self {
        case .command: return .command
        case .shift: return .shift
        case .option: return .option
        case .control: return .control
        }
    }
}

extension Set<ModifierKey> {
    var eventModifiers: EventModifiers {
        reduce(into: EventModifiers()) { $0.insert($1.eventModifier) }
    }

    /// Symbols in the conventional macOS menu order: ⌃⌥⇧⌘.
    var symbol: String {
        [ModifierKey.control, .option, .shift, .command]
            .filter(contains)
            .map(\.symbol)
            .joined()
    }
}

/// The non-modifier half of a shortcut — either a plain character or one of
/// the named keys menu shortcuts commonly use. Custom `Codable`: `Character`
/// itself isn't `Codable`, so `.character` round-trips through a 1-character
/// `String`.
enum ShortcutKey: Equatable {
    case character(Character)
    case special(Special)

    enum Special: String, Codable, CaseIterable {
        case `return`, tab, escape, delete, space, leftArrow, rightArrow, upArrow, downArrow
    }

    var keyEquivalent: KeyEquivalent {
        switch self {
        case .character(let c): return KeyEquivalent(c)
        case .special(.return): return .return
        case .special(.tab): return .tab
        case .special(.escape): return .escape
        case .special(.delete): return .delete
        case .special(.space): return .space
        case .special(.leftArrow): return .leftArrow
        case .special(.rightArrow): return .rightArrow
        case .special(.upArrow): return .upArrow
        case .special(.downArrow): return .downArrow
        }
    }

    var displaySymbol: String {
        switch self {
        case .character(let c): return String(c).uppercased()
        case .special(.return): return "↩"
        case .special(.tab): return "⇥"
        case .special(.escape): return "⎋"
        case .special(.delete): return "⌫"
        case .special(.space): return "␣"
        case .special(.leftArrow): return "←"
        case .special(.rightArrow): return "→"
        case .special(.upArrow): return "↑"
        case .special(.downArrow): return "↓"
        }
    }

    /// Builds a key from a raw `NSEvent.charactersIgnoringModifiers` string
    /// and key code, for the shortcut recorder. Arrow/return/etc. keys report
    /// private-use-area characters that aren't meaningful as literal text, so
    /// those key codes are matched explicitly first.
    static func from(charactersIgnoringModifiers: String?, keyCode: UInt16) -> ShortcutKey? {
        switch keyCode {
        case 36, 76: return .special(.return)      // Return, keypad Enter
        case 48: return .special(.tab)
        case 53: return .special(.escape)
        case 51, 117: return .special(.delete)     // Delete, forward-delete
        case 49: return .special(.space)
        case 123: return .special(.leftArrow)
        case 124: return .special(.rightArrow)
        case 126: return .special(.upArrow)
        case 125: return .special(.downArrow)
        default:
            guard let c = charactersIgnoringModifiers?.lowercased().first else { return nil }
            return .character(c)
        }
    }
}

extension ShortcutKey: Codable {
    private enum CodingKeys: String, CodingKey { case character, special }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let special = try c.decodeIfPresent(Special.self, forKey: .special) {
            self = .special(special)
        } else if let string = try c.decodeIfPresent(String.self, forKey: .character), let char = string.first {
            self = .character(char)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "Empty ShortcutKey"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .character(let char): try c.encode(String(char), forKey: .character)
        case .special(let special): try c.encode(special, forKey: .special)
        }
    }
}

/// A key plus the modifiers held with it.
struct KeyBinding: Codable, Equatable {
    var key: ShortcutKey
    var modifiers: Set<ModifierKey>

    var displaySymbol: String { modifiers.symbol + key.displaySymbol }
}

/// Every shortcut Portside offers that's worth letting a user rebind. Deliberately
/// excludes "Go to Tab 1–9" (nine near-identical rows isn't worth the settings
/// real estate) and the ⌘←/⌘→ tab-cycling alias (a fixed convenience binding
/// alongside the real, remappable ⇧⌘[/⇧⌘] — see `SessionManager`'s key monitor).
enum ShortcutAction: String, CaseIterable, Codable, Identifiable {
    case newLocalShell, quickConnect, find
    case zoomIn, zoomOut, actualSize
    case splitRight, splitDown, zoomPane, focusNextPane, focusPreviousPane, closePane
    case nextTab, previousTab, reopenClosedTab, toggleMultiExec, toggleGridView, clearBuffer

    var id: String { rawValue }

    var category: String {
        switch self {
        case .newLocalShell, .quickConnect, .nextTab, .previousTab, .reopenClosedTab:
            return "Tabs"
        case .splitRight, .splitDown, .zoomPane, .focusNextPane, .focusPreviousPane, .closePane:
            return "Panes"
        case .find, .zoomIn, .zoomOut, .actualSize, .toggleMultiExec, .toggleGridView, .clearBuffer:
            return "Terminal"
        }
    }

    /// Category display order in the settings list.
    static let categoryOrder = ["Tabs", "Panes", "Terminal"]

    var label: String {
        switch self {
        case .newLocalShell: return "New Local Shell"
        case .quickConnect: return "Quick Connect"
        case .find: return "Find"
        case .zoomIn: return "Zoom In"
        case .zoomOut: return "Zoom Out"
        case .actualSize: return "Actual Size"
        case .splitRight: return "Split Right"
        case .splitDown: return "Split Down"
        case .zoomPane: return "Zoom Pane"
        case .focusNextPane: return "Focus Next Pane"
        case .focusPreviousPane: return "Focus Previous Pane"
        case .closePane: return "Close Pane"
        case .nextTab: return "Show Next Tab"
        case .previousTab: return "Show Previous Tab"
        case .reopenClosedTab: return "Reopen Closed Tab"
        case .toggleMultiExec: return "Toggle MultiExec"
        case .toggleGridView: return "Toggle Grid View"
        case .clearBuffer: return "Clear Buffer"
        }
    }

    /// Today's hardcoded values, preserved exactly as before so existing
    /// muscle memory doesn't change without an explicit remap.
    var defaultBinding: KeyBinding {
        switch self {
        case .newLocalShell: return KeyBinding(key: .character("t"), modifiers: [.command])
        case .quickConnect: return KeyBinding(key: .character("k"), modifiers: [.command])
        case .find: return KeyBinding(key: .character("f"), modifiers: [.command])
        case .zoomIn: return KeyBinding(key: .character("+"), modifiers: [.command])
        case .zoomOut: return KeyBinding(key: .character("-"), modifiers: [.command])
        case .actualSize: return KeyBinding(key: .character("0"), modifiers: [.command])
        case .splitRight: return KeyBinding(key: .character("d"), modifiers: [.command])
        case .splitDown: return KeyBinding(key: .character("d"), modifiers: [.command, .shift])
        case .zoomPane: return KeyBinding(key: .special(.return), modifiers: [.command, .shift])
        case .focusNextPane: return KeyBinding(key: .special(.rightArrow), modifiers: [.command, .option])
        case .focusPreviousPane: return KeyBinding(key: .special(.leftArrow), modifiers: [.command, .option])
        case .closePane: return KeyBinding(key: .character("w"), modifiers: [.command, .shift])
        case .nextTab: return KeyBinding(key: .character("]"), modifiers: [.command, .shift])
        case .previousTab: return KeyBinding(key: .character("["), modifiers: [.command, .shift])
        case .reopenClosedTab: return KeyBinding(key: .character("t"), modifiers: [.command, .shift])
        case .toggleMultiExec: return KeyBinding(key: .character("m"), modifiers: [.command, .shift])
        case .toggleGridView: return KeyBinding(key: .character("g"), modifiers: [.command, .shift])
        case .clearBuffer: return KeyBinding(key: .special(.delete), modifiers: [.command])
        }
    }
}

/// User overrides of `ShortcutAction`'s default bindings, persisted in the
/// session library. Stored as a plain `[String: KeyBinding]` (keyed by the
/// action's raw value) rather than `[ShortcutAction: KeyBinding]` so it stays
/// trivially, tolerantly `Codable` — an action missing from `overrides`
/// (whether never remapped, or added to `ShortcutAction` after this was
/// saved) just falls back to its default.
struct KeyBindings: Codable, Equatable {
    private var overrides: [String: KeyBinding] = [:]

    func binding(for action: ShortcutAction) -> KeyBinding {
        overrides[action.rawValue] ?? action.defaultBinding
    }

    /// Whether this action's binding was customized away from its default.
    func isCustomized(_ action: ShortcutAction) -> Bool {
        overrides[action.rawValue] != nil
    }

    mutating func set(_ binding: KeyBinding, for action: ShortcutAction) {
        overrides[action.rawValue] = binding
    }

    mutating func reset(_ action: ShortcutAction) {
        overrides[action.rawValue] = nil
    }

    mutating func resetAll() {
        overrides.removeAll()
    }

    /// The other action already using this exact binding, if any — drives the
    /// settings UI's collision warning before letting a rebind through.
    func conflict(with binding: KeyBinding, excluding: ShortcutAction) -> ShortcutAction? {
        ShortcutAction.allCases.first { $0 != excluding && self.binding(for: $0) == binding }
    }
}
