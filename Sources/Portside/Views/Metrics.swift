import Foundation

/// Shared spacing values.
///
/// The sheet-style views — coverage, history, log search, port forwarding,
/// credential profiles, container picker — were each built independently, and
/// each picked its own numbers: 10pt padding in some headers, 12 in others,
/// content insets that did not match the header above them. Individually
/// invisible; together they are why the app looks assembled rather than
/// designed.
///
/// Deliberately small. This is a set of agreed numbers, not a design system —
/// anything more would be inventing structure the app has not asked for.
enum Metrics {
    /// Padding around a sheet's header or footer bar.
    static let sheetChrome: CGFloat = 12
    /// Padding around a sheet's scrolling content, matching the chrome above it.
    static let sheetContent: CGFloat = 12
    /// Gap between stacked cards or rows in a list-like body.
    static let cardSpacing: CGFloat = 10
    /// Padding inside a card.
    static let cardPadding: CGFloat = 8
    /// Gap between an icon and its label, or between adjacent controls.
    static let inlineSpacing: CGFloat = 6
    /// Capsule badge insets. Was 5pt in two views and 6pt in a third.
    static let badgeHorizontal: CGFloat = 6
    static let badgeVertical: CGFloat = 2
}
