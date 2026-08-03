import Foundation

/// "2 minutes ago" for menu entries.
///
/// Both the Recently Closed and Recently Deleted menus can list several rows
/// with the same label — close two tabs on `web-01`, delete two hosts called
/// `db-01` from different folders — and a name on its own gives you no way to
/// tell which one you're about to bring back. Both rings already recorded a
/// timestamp for exactly this and neither ever read it.
///
/// Joined onto the label with a middle dot, matching how the sidebar and Quick
/// Connect already layer secondary detail — a split tab reads
/// "hopper — 3 panes · 2 minutes ago", with the em dash for what it is and the
/// dot for when.
///
/// `now` is a parameter rather than `Date()` so the wording is testable without
/// waiting for real time to pass.
enum RelativeTime {
    static func phrase(for date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        // "now" rather than "in 0 seconds": a menu opened immediately after the
        // action should not describe it in the future, which is what rounding a
        // few milliseconds the wrong way produces.
        formatter.dateTimeStyle = .named
        guard date <= now else { return "just now" }
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
