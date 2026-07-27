import AppKit
import SwiftUI

/// Sizes the Settings window to whichever tab is showing.
///
/// SwiftUI's `Settings` scene sizes its window once and then leaves it alone, so
/// the window kept whatever height the *previous* tab needed: Appearance is tall
/// and Profiles is short, so arriving at Recording from Profiles left a long
/// page crammed into a short window, and arriving from Appearance left a short
/// page floating in a tall one. Each page also declared its own width, between
/// 420 and 520, so the window changed shape as you moved across the tabs.
///
/// Two rules:
///
/// 1. If the content fits on screen, the window grows to show all of it.
/// 2. If it does not, the window stops at the screen and the page scrolls —
///    and the window stays **resizable**, so auto-sizing is a starting point
///    rather than a cage.
///
/// Both are done through SwiftUI's own layout rather than by measuring and
/// calling `setContentSize`. An earlier attempt measured in AppKit and silently
/// did nothing: SwiftUI's Settings window has no `contentViewController`, so the
/// measurement guard returned early every time, and the per-tab sizing that
/// appeared to work was SwiftUI responding to the pin below. Pinning is the
/// whole mechanism; there is nothing else to do.
enum SettingsWindowSizer {

    /// One width for every tab. A settings window that changes width as you
    /// move between tabs reads as a glitch, and the widest page needs 520.
    static let width: CGFloat = 520

    /// Left free around the window so a "fits on screen" window does not sit
    /// edge to edge against the menu bar and the Dock.
    private static let screenMargin: CGFloat = 80

    /// The tallest a page may ask to be. Beyond this it scrolls instead, which
    /// is rule 2 — without the cap a long page on a short display would open a
    /// window taller than the screen, with its bottom edge unreachable.
    static var maxPageHeight: CGFloat {
        let visible = NSScreen.main?.visibleFrame.height ?? 900
        return max(320, visible - screenMargin)
    }

    /// Marks the Settings window resizable. SwiftUI does not, and the auto-size
    /// is meant to be a starting point rather than a cage.
    static func makeResizable() {
        DispatchQueue.main.async {
            NSApp.windows
                .filter { ($0.identifier?.rawValue ?? "").contains("Settings") }
                .forEach { $0.styleMask.insert(.resizable) }
        }
    }

    /// Re-pins the pages so the newly selected tab is measured at its own
    /// content height, then releases the pin so the window can still be dragged
    /// smaller than its content.
    static func fitToContent() {
        SettingsSizingState.shared.pinned = true
        makeResizable()
        // Two turns: one for SwiftUI to lay out at the pinned height and for the
        // window to follow it, then release.
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                SettingsSizingState.shared.pinned = false
            }
        }
    }
}

/// Whether settings pages are currently pinned to their full content height.
///
/// Pinned, a page reports the height it actually wants and the window follows
/// it. Unpinned, the page accepts any height, so the window can be dragged
/// smaller and the page scrolls. It has to be both: pinning permanently makes
/// the window unshrinkable, and never pinning makes every tab report its bare
/// minimum — which is how they all ended up the same height.
///
/// Shared rather than per-page because the pin is driven from the tab selection
/// in `PortsideApp`, which does not know which page is on screen.
final class SettingsSizingState: ObservableObject {
    static let shared = SettingsSizingState()
    @Published var pinned = true
    private init() {}
}

/// Applies the shared width and takes part in the pin-then-release dance.
///
/// Every settings page carries this instead of its own `.frame(...)`, which is
/// where the inconsistent widths came from.
struct SettingsPageSizing: ViewModifier {
    @ObservedObject private var state = SettingsSizingState.shared

    func body(content: Content) -> some View {
        content
            .frame(width: SettingsWindowSizer.width)
            // The cap goes *before* the pin so the pin adopts the already-capped
            // ideal height. After the pin it only sets an upper bound, which
            // leaves the window free to keep whatever height it had — so tabs
            // grew into the tallest page and never shrank back.
            .frame(maxHeight: SettingsWindowSizer.maxPageHeight)
            .fixedSize(horizontal: false, vertical: state.pinned)
            .onAppear { SettingsWindowSizer.fitToContent() }
    }
}

extension View {
    func settingsPageSizing() -> some View {
        modifier(SettingsPageSizing())
    }
}
