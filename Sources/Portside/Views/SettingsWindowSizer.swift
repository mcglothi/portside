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
/// 2. If it does not, the window stops at the screen and the page scrolls. The
///    pages are grouped `Form`s and scrolled before any of this existed, so
///    nothing here can make content unreachable.
///
/// **Manual resizing is only partly working.** `.resizable` is set, and the
/// window can be dragged while the screen cap is actively constraining the page
/// — measured by forcing the cap below the content height. On the ordinary path,
/// where the page is shorter than the screen, the window snaps straight back to
/// the content's ideal height, so a drag does not stick. The pin is released
/// and the constraints do relax (`contentMin` drops to 88, `contentMax` to
/// infinity), so the block is SwiftUI re-imposing the ideal size rather than a
/// leftover constraint of ours. Unresolved; auto-sizing plus scrolling is what
/// actually carries the behaviour today.
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

    /// The shortest a page may be measured as.
    ///
    /// Not defensive padding — it fixes a real collapse. A page built on `List`
    /// rather than `Form` has no intrinsic content height, because `List` is
    /// lazy and does not know how tall its rows are until it lays them out. The
    /// pin therefore measures it as its bare minimum: Profiles came out **152
    /// points** against Appearance's 993, showing a header and half a row.
    ///
    /// Only reproducible with credential profiles saved — an empty Profiles tab
    /// draws an `EmptyStateView`, which does report a height, so the tab
    /// measured fine on a machine that had never added one. Reported from a
    /// work machine on 0.17.0.
    static let minPageHeight: CGFloat = 420

    /// The tallest a page may ask to be. Beyond this it scrolls instead, which
    /// is rule 2 — without the cap a long page on a short display would open a
    /// window taller than the screen, with its bottom edge unreachable.
    /// `PORTSIDE_SETTINGS_MAX_HEIGHT` forces the cap, so the small-screen path
    /// can be exercised without changing display resolution. The interesting
    /// case is a page taller than the screen, and on a large display no page
    /// reaches that — so without a seam the scrolling path never gets tested.
    static var maxPageHeight: CGFloat {
        if let override = ProcessInfo.processInfo.environment["PORTSIDE_SETTINGS_MAX_HEIGHT"],
           let forced = Double(override) {
            return CGFloat(forced)
        }
        let visible = NSScreen.main?.visibleFrame.height ?? 900
        return max(320, visible - screenMargin)
    }

    /// SwiftUI's own name for the window. Matched exactly: the *main* window's
    /// identifier is a SwiftUI type name that happens to contain
    /// "TerminalSettings" and "LoggingSettings", so a `contains("Settings")`
    /// test picks it up too.
    private static let settingsWindowIdentifier = "com_apple_SwiftUI_Settings_window"

    /// Marks the Settings window resizable. SwiftUI does not, and it strips the
    /// flag again while laying a page out — hence the second call after the pin
    /// is released. See the type comment: this makes the control appear and work
    /// while the screen cap binds, but does not fully survive on the ordinary
    /// path.
    static func makeResizable() {
        DispatchQueue.main.async {
            NSApp.windows
                .filter { $0.identifier?.rawValue == Self.settingsWindowIdentifier }
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
                // Again, after the pin is released. SwiftUI resets the style
                // mask while it is laying the page out, so setting this only at
                // the start left the window with relaxed constraints and no
                // resize control -- looking adjustable and refusing to move.
                makeResizable()
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
            // Every bound is relaxed once unpinned. Holding a fixed width and a
            // capped height permanently left the window with contentMin equal
            // to contentMax, so it could not be dragged at all — `.resizable`
            // was in the style mask and did nothing.
            //
            // The cap goes *before* the pin so the pin adopts the already-capped
            // ideal height. After the pin it is only an upper bound, which
            // leaves the window free to keep whatever height it had — so tabs
            // grew into the tallest page and never shrank back.
            // The floor goes on with the cap, before the pin, so the pinned
            // ideal is already clamped at both ends — after the pin they are
            // only advisory and the window keeps whatever it had.
            .frame(
                minWidth: SettingsWindowSizer.width,
                idealWidth: SettingsWindowSizer.width,
                maxWidth: state.pinned ? SettingsWindowSizer.width : .infinity,
                minHeight: state.pinned ? SettingsWindowSizer.minPageHeight : nil,
                maxHeight: state.pinned ? SettingsWindowSizer.maxPageHeight : .infinity
            )
            .fixedSize(horizontal: false, vertical: state.pinned)
            .onAppear { SettingsWindowSizer.fitToContent() }
    }
}

extension View {
    func settingsPageSizing() -> some View {
        modifier(SettingsPageSizing())
    }
}
